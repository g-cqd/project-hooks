import Foundation

/// A detected project/module boundary with its associated test command.
public struct DetectedModule: Equatable {
    /// The module's display name.
    public let name: String
    /// The module's path relative to the repository root.
    public let path: String
    /// The command that tests the module, or an empty array if no runner is available.
    public let testCommand: [String]

    /// The detected module and the command that tests it.
    public init(name: String, path: String, testCommand: [String]) {
        self.name = name
        self.path = path
        self.testCommand = testCommand
    }
}

/// Resolves which test targets to run based on changed files.
public enum TestTargetResolver {
    /// Marker files that indicate a Swift package boundary.
    static let swiftPackageMarkers = ["Package.swift"]

    /// Marker files that indicate a Gradle module boundary.
    static let gradleModuleMarkers = ["build.gradle", "build.gradle.kts"]

    /// Find the closest project/module boundary for a file by walking up the directory tree.
    ///
    /// Returns the relative path from repoRoot to the module root, or nil.
    public static func findClosestModule(
        forFile relativePath: String,
        repoRoot: String,
        platform: Platform,
    ) -> String? {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: repoRoot).standardized
        var current = rootURL.appendingPathComponent(relativePath).deletingLastPathComponent().standardized

        let markers: [String] =
            switch platform {
                case .ios: swiftPackageMarkers
                case .android: gradleModuleMarkers
                case .mixed: swiftPackageMarkers + gradleModuleMarkers
                case .unknown: []
            }

        while current.path.hasPrefix(rootURL.path) {
            for marker in markers where fileManager.fileExists(atPath: current.appendingPathComponent(marker).path) {
                return makeRelativePath(from: rootURL, to: current)
            }

            // Check for .xcodeproj directories (iOS)
            if platform == .ios || platform == .mixed {
                if let contents = try? fileManager.contentsOfDirectory(atPath: current.path),
                    contents.contains(where: { $0.hasSuffix(".xcodeproj") })
                {
                    return makeRelativePath(from: rootURL, to: current)
                }
            }

            let parent = current.deletingLastPathComponent().standardized
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    /// Detect all unique modules touched by the given changed files.
    ///
    /// Each module includes its test command.
    public static func detectModules(
        changedFiles: [String],
        repoRoot: String,
        platform: Platform,
    ) -> [DetectedModule] {
        var seen = Set<String>()
        var modules: [DetectedModule] = []

        for file in changedFiles {
            guard let modulePath = findClosestModule(forFile: file, repoRoot: repoRoot, platform: platform) else {
                continue
            }
            guard seen.insert(modulePath).inserted else { continue }

            let absoluteModulePath =
                modulePath == "."
                ? repoRoot
                : URL(fileURLWithPath: repoRoot).appendingPathComponent(modulePath).path

            let name = modulePath == "." ? URL(fileURLWithPath: repoRoot).lastPathComponent : modulePath

            modules.append(
                DetectedModule(
                    name: name,
                    path: modulePath,
                    testCommand: buildTestCommand(modulePath: absoluteModulePath, repoRoot: repoRoot),
                ))
        }

        return modules
    }

    /// The test command for the package or project at `modulePath`, or an empty array when none is detected.
    public static func buildTestCommand(modulePath: String, repoRoot: String) -> [String] {
        let fileManager = FileManager.default
        let moduleURL = URL(fileURLWithPath: modulePath)

        // Swift Package Manager. Scratch path is injected by the CLI runner via BuildIsolation
        // so creation and cleanup live in one place.
        if fileManager.fileExists(atPath: moduleURL.appendingPathComponent("Package.swift").path) {
            return ["swift", "test", "--package-path", modulePath]
        }

        // Xcode project. Same isolation note as above — derivedDataPath is set at run time.
        if let contents = try? fileManager.contentsOfDirectory(atPath: modulePath),
            let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") })
        {
            let projectName = (xcodeproj as NSString).deletingPathExtension
            return [
                "xcodebuild", "test",
                "-project", moduleURL.appendingPathComponent(xcodeproj).path,
                "-scheme", projectName,
                "-destination",
                ProcessInfo.processInfo.environment["GITHOOKS_DESTINATION"]
                    ?? "generic/platform=iOS Simulator",
            ]
        }

        // Gradle module. Gradle doesn't have a flag matching xcodebuild/SwiftPM cleanly, so it
        // keeps its in-tree build/ directory; isolation here is out of scope of the runner's
        // shared scratch logic.
        for gradleFile in ["build.gradle.kts", "build.gradle"]
        where fileManager.fileExists(atPath: moduleURL.appendingPathComponent(gradleFile).path) {
            let gradlew = findGradleWrapper(from: modulePath, repoRoot: repoRoot)
            return [gradlew, "-p", modulePath, "test", "--build-cache"]
        }

        return []
    }

    private static func makeRelativePath(from rootURL: URL, to current: URL) -> String {
        if current.path == rootURL.path { return "." }
        let relative = String(current.path.dropFirst(rootURL.path.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    private static func findGradleWrapper(from modulePath: String, repoRoot: String) -> String {
        let rootPath = URL(fileURLWithPath: repoRoot).standardized.path
        var current = URL(fileURLWithPath: modulePath)
        while current.path.hasPrefix(rootPath) {
            let wrapper = current.appendingPathComponent("gradlew").path
            if FileManager.default.isExecutableFile(atPath: wrapper) {
                return wrapper
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return "gradle"
    }
}
