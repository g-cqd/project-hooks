import Foundation

/// A linter that can be discovered and run against staged files.
public struct DiscoveredLinter: Equatable {
    public let name: String
    public let executablePath: String
    public let configCandidates: [String]
    public let platform: Platform
    /// When true, the linter only runs if a config file is found in the repo.
    ///
    /// Built-in toolchain linters (swift-format) have sensible defaults and don't require config.
    public let requiresConfig: Bool
    /// When true, the linter is invoked via `swift format` subcommand instead of a standalone binary.
    public let usesSwiftSubcommand: Bool

    public init(
        name: String,
        executablePath: String,
        configCandidates: [String],
        platform: Platform,
        requiresConfig: Bool = true,
        usesSwiftSubcommand: Bool = false,
    ) {
        self.name = name
        self.executablePath = executablePath
        self.configCandidates = configCandidates
        self.platform = platform
        self.requiresConfig = requiresConfig
        self.usesSwiftSubcommand = usesSwiftSubcommand
    }
}

/// Discovers available linters on the system for a given platform.
public enum LinterDiscovery {
    private struct LinterDefinition {
        let name: String
        let binary: String
        let configCandidates: [String]
        let requiresConfig: Bool
        /// When true, falls back to resolving via `swift` binary if the standalone binary is not found.
        let canFallbackToSwift: Bool

        init(
            name: String,
            binary: String,
            configCandidates: [String],
            requiresConfig: Bool,
            canFallbackToSwift: Bool = false,
        ) {
            self.name = name
            self.binary = binary
            self.configCandidates = configCandidates
            self.requiresConfig = requiresConfig
            self.canFallbackToSwift = canFallbackToSwift
        }
    }

    private static let iosDefinitions: [LinterDefinition] = [
        LinterDefinition(
            name: "SwiftLint",
            binary: "swiftlint",
            configCandidates: [".swiftlint.yml", ".swiftlint.yaml"],
            requiresConfig: true,
        ),
        LinterDefinition(
            name: "SwiftFormat",
            binary: "swiftformat",
            configCandidates: [".swiftformat"],
            requiresConfig: true,
        ),
        LinterDefinition(
            name: "swift-format",
            binary: "swift-format",
            configCandidates: [".swift-format"],
            requiresConfig: true,
            canFallbackToSwift: true,
        ),
    ]

    private static let androidDefinitions: [LinterDefinition] = [
        LinterDefinition(
            name: "ktlint",
            binary: "ktlint",
            configCandidates: [".editorconfig", ".ktlint"],
            requiresConfig: true,
        ),
        LinterDefinition(
            name: "detekt",
            binary: "detekt",
            configCandidates: ["detekt.yml", "detekt.yaml", "config/detekt/detekt.yml"],
            requiresConfig: true,
        ),
    ]

    public static let knownIOSLinters = iosDefinitions.map(\.name)
    public static let knownAndroidLinters = androidDefinitions.map(\.name)

    /// Discover all available linters for the given platform.
    public static func discoverLinters(
        forPlatform platform: Platform,
        repoRoot: String,
        fallbackPaths: [String: String] = [:],
    ) -> [DiscoveredLinter] {
        let definitions: [(def: LinterDefinition, platform: Platform)]
        switch platform {
            case .ios: definitions = iosDefinitions.map { ($0, .ios) }
            case .android: definitions = androidDefinitions.map { ($0, .android) }
            case .mixed:
                definitions = iosDefinitions.map { ($0, .ios) } + androidDefinitions.map { ($0, .android) }
            case .unknown: return []
        }

        return definitions.compactMap { item in
            // Try the standalone binary first
            if let execPath = resolveExecutable(
                name: item.def.binary,
                fallbackRelativePath: fallbackPaths[item.def.binary],
                repoRoot: repoRoot,
            ) {
                return DiscoveredLinter(
                    name: item.def.name,
                    executablePath: execPath,
                    configCandidates: item.def.configCandidates,
                    platform: item.platform,
                    requiresConfig: item.def.requiresConfig,
                )
            }

            // Fall back to `swift` binary for tools bundled in the Swift toolchain
            if item.def.canFallbackToSwift,
                let swiftPath = resolveExecutable(name: "swift", fallbackRelativePath: nil, repoRoot: repoRoot)
            {
                return DiscoveredLinter(
                    name: item.def.name,
                    executablePath: swiftPath,
                    configCandidates: item.def.configCandidates,
                    platform: item.platform,
                    requiresConfig: item.def.requiresConfig,
                    usesSwiftSubcommand: true,
                )
            }

            return nil
        }
    }

    /// Find the file extension filter for a linter's platform.
    public static func fileExtensions(for platform: Platform) -> [String] {
        switch platform {
            case .ios: [".swift"]
            case .android: [".kt", ".kts", ".java"]
            case .mixed: [".swift", ".kt", ".kts", ".java"]
            case .unknown: []
        }
    }

    /// Filter files to those relevant for a specific linter's platform.
    public static func filterFiles(_ files: [String], forPlatform platform: Platform) -> [String] {
        let extensions = fileExtensions(for: platform)
        return files.filter { file in extensions.contains(where: { file.hasSuffix($0) }) }
    }

    private static func resolveExecutable(
        name: String,
        fallbackRelativePath: String?,
        repoRoot: String,
    ) -> String? {
        // Check PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]

        let preferredPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        var pathEntries = currentPath.split(separator: ":").map(String.init)
        for path in preferredPaths.reversed() where !pathEntries.contains(path) {
            pathEntries.insert(path, at: 0)
        }
        env["PATH"] = pathEntries.joined(separator: ":")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            }
        } catch {}

        // Check fallback path
        if let fallback = fallbackRelativePath {
            let fullPath = URL(fileURLWithPath: repoRoot).appendingPathComponent(fallback).path
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        return nil
    }
}
