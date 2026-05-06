import Foundation

/// A detected project/module boundary with its associated test command.
public struct DetectedModule: Equatable {
    public let name: String
    public let path: String
    public let testCommand: [String]
    public let buildCommand: [String]

    public init(name: String, path: String, testCommand: [String], buildCommand: [String]) {
        self.name = name
        self.path = path
        self.testCommand = testCommand
        self.buildCommand = buildCommand
    }
}

/// Resolves which test targets to run based on changed files.
public enum TestTargetResolver {
    /// Marker files that indicate a Swift package boundary.
    static let swiftPackageMarkers = ["Package.swift"]

    /// Marker files that indicate a Gradle module boundary.
    static let gradleModuleMarkers = ["build.gradle", "build.gradle.kts"]

    /// Find the closest project/module boundary for a file by walking up the directory tree.
    /// Returns the relative path from repoRoot to the module root, or nil.
    public static func findClosestModule(
        forFile relativePath: String,
        repoRoot: String,
        platform: Platform,
    ) -> String? {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: repoRoot).standardized
        var current = rootURL.appendingPathComponent(relativePath).deletingLastPathComponent().standardized

        let markers: [String] = switch platform {
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
                   contents.contains(where: { $0.hasSuffix(".xcodeproj") }) {
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
    /// Each module includes both test and build commands pre-computed.
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

            let absoluteModulePath = modulePath == "."
                ? repoRoot
                : URL(fileURLWithPath: repoRoot).appendingPathComponent(modulePath).path

            let name = modulePath == "." ? URL(fileURLWithPath: repoRoot).lastPathComponent : modulePath

            modules.append(DetectedModule(
                name: name,
                path: modulePath,
                testCommand: buildTestCommand(modulePath: absoluteModulePath, repoRoot: repoRoot),
                buildCommand: buildBuildCommand(modulePath: absoluteModulePath, repoRoot: repoRoot),
            ))
        }

        return modules
    }

    public static func buildTestCommand(modulePath: String, repoRoot: String) -> [String] {
        buildCommand(action: .test, modulePath: modulePath, repoRoot: repoRoot)
    }

    public static func buildBuildCommand(modulePath: String, repoRoot: String) -> [String] {
        buildCommand(action: .build, modulePath: modulePath, repoRoot: repoRoot)
    }

    private enum BuildAction {
        case test, build

        var swiftVerb: String {
            self == .test ? "test" : "build"
        }

        var xcodeVerb: String {
            self == .test ? "test" : "build"
        }

        var gradleTask: String {
            self == .test ? "test" : "assembleDebug"
        }
    }

    private static func buildCommand(action: BuildAction, modulePath: String, repoRoot: String) -> [String] {
        let fileManager = FileManager.default
        let scratchDir = isolatedBuildDir(for: modulePath)
        let moduleURL = URL(fileURLWithPath: modulePath)

        // Swift Package Manager
        if fileManager.fileExists(atPath: moduleURL.appendingPathComponent("Package.swift").path) {
            return ["swift", action.swiftVerb, "--package-path", modulePath, "--scratch-path", scratchDir]
        }

        // Xcode project
        if let contents = try? fileManager.contentsOfDirectory(atPath: modulePath),
           let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let projectName = (xcodeproj as NSString).deletingPathExtension
            return [
                "xcodebuild", action.xcodeVerb,
                "-project", moduleURL.appendingPathComponent(xcodeproj).path,
                "-scheme", projectName,
                "-destination",
                ProcessInfo.processInfo.environment["GITHOOKS_DESTINATION"]
                    ?? "platform=iOS Simulator,name=iPhone 16",
                "-derivedDataPath", scratchDir,
            ]
        }

        // Gradle module
        for gradleFile in ["build.gradle.kts", "build.gradle"]
            where fileManager.fileExists(atPath: moduleURL.appendingPathComponent(gradleFile).path) {
            let gradlew = findGradleWrapper(from: modulePath, repoRoot: repoRoot)
            return [
                gradlew, "-p", modulePath, action.gradleTask,
                "--build-cache",
                "-Dorg.gradle.project.buildDir=\(scratchDir)",
            ]
        }

        return []
    }

    /// Generate a unique, isolated build directory for a module.
    /// Prevents conflicts with Xcode's shared DerivedData, SPM's .build, or Gradle's build/.
    private static func isolatedBuildDir(for modulePath: String) -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let moduleName = URL(fileURLWithPath: modulePath).lastPathComponent
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("project-hooks-build")
            .appendingPathComponent("\(moduleName)-\(pid)")
            .path
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
