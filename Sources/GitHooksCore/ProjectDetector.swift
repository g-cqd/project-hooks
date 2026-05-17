import Foundation

/// The development platform detected in a repository.
public enum Platform: String {
    case ios
    case android
    case mixed
    case unknown
}

/// Detects platform and available tooling for a repository.
public enum ProjectDetector {
    /// Detect the development platform by scanning the repo root for project marker files.
    public static func detectPlatform(repoRoot: String) -> Platform {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: repoRoot)

        let hasSwiftPackage = fileManager.fileExists(atPath: rootURL.appendingPathComponent("Package.swift").path)

        let rootContents = (try? fileManager.contentsOfDirectory(atPath: repoRoot)) ?? []
        let hasXcodeproj = rootContents.contains {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
        }

        let hasGradleBuild =
            fileManager.fileExists(atPath: rootURL.appendingPathComponent("build.gradle").path)
            || fileManager.fileExists(atPath: rootURL.appendingPathComponent("build.gradle.kts").path)
        let hasSettingsGradle =
            fileManager.fileExists(atPath: rootURL.appendingPathComponent("settings.gradle").path)
            || fileManager.fileExists(atPath: rootURL.appendingPathComponent("settings.gradle.kts").path)

        let isIOS = hasSwiftPackage || hasXcodeproj
        let isAndroid = hasGradleBuild || hasSettingsGradle

        if isIOS, isAndroid { return .mixed }
        if isIOS { return .ios }
        if isAndroid { return .android }
        return .unknown
    }

    /// Detect platform from staged file extensions alone (cheaper than scanning the repo root).
    public static func detectPlatformFromFiles(_ files: [String]) -> Platform {
        var hasSwift = false
        var hasKotlin = false
        var hasJava = false

        for file in files {
            if file.hasSuffix(".swift") { hasSwift = true }
            if file.hasSuffix(".kt") || file.hasSuffix(".kts") { hasKotlin = true }
            if file.hasSuffix(".java") { hasJava = true }
        }

        let isIOS = hasSwift
        let isAndroid = hasKotlin || hasJava

        if isIOS, isAndroid { return .mixed }
        if isIOS { return .ios }
        if isAndroid { return .android }
        return .unknown
    }
}
