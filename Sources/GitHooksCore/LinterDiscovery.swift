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
    /// Where the binary came from, when discovery chose it by a rule other than `PATH` lookup.
    public let origin: String?

    public init(
        name: String,
        executablePath: String,
        configCandidates: [String],
        platform: Platform,
        requiresConfig: Bool = true,
        usesSwiftSubcommand: Bool = false,
        origin: String? = nil,
    ) {
        self.name = name
        self.executablePath = executablePath
        self.configCandidates = configCandidates
        self.platform = platform
        self.requiresConfig = requiresConfig
        self.usesSwiftSubcommand = usesSwiftSubcommand
        self.origin = origin
    }
}

/// Discovers available linters on the system for a given platform.
public enum LinterDiscovery {
    private struct LinterDefinition {
        let name: String
        let binary: String
        let configCandidates: [String]
        let requiresConfig: Bool
        /// When true, the binary comes from a Swift toolchain chosen by `SwiftFormatResolver`, not from `PATH`.
        let comesFromSwiftToolchain: Bool

        init(
            name: String,
            binary: String,
            configCandidates: [String],
            requiresConfig: Bool,
            comesFromSwiftToolchain: Bool = false,
        ) {
            self.name = name
            self.binary = binary
            self.configCandidates = configCandidates
            self.requiresConfig = requiresConfig
            self.comesFromSwiftToolchain = comesFromSwiftToolchain
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
            comesFromSwiftToolchain: true,
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
    ///
    /// swift-format comes from `SwiftFormatResolver`, so that the same staged files meet the same swift-format whatever
    /// `PATH` the hook inherits. The other linters come from `PATH`, then from `fallbackPaths`.
    /// - Parameters:
    ///   - platform: The platform whose linters to look for.
    ///   - repoRoot: The repository's working tree, whose `.swift-version` selects swift-format.
    ///   - fallbackPaths: Paths relative to `repoRoot` to try, by binary name, when `PATH` has no such binary.
    /// - Returns: The linters that were found, in the platform's order.
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
            if item.def.comesFromSwiftToolchain {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                guard let resolution = SwiftFormatResolver.resolve(repoRoot: repoRoot, home: home) else { return nil }
                return DiscoveredLinter(
                    name: item.def.name,
                    executablePath: resolution.executablePath,
                    configCandidates: item.def.configCandidates,
                    platform: item.platform,
                    requiresConfig: item.def.requiresConfig,
                    origin: [resolution.origin, resolution.fallbackReason].compactMap(\.self).joined(separator: "; "),
                )
            }

            guard
                let execPath = resolveExecutable(
                    name: item.def.binary,
                    fallbackRelativePath: fallbackPaths[item.def.binary],
                    repoRoot: repoRoot,
                )
            else { return nil }
            return DiscoveredLinter(
                name: item.def.name,
                executablePath: execPath,
                configCandidates: item.def.configCandidates,
                platform: item.platform,
                requiresConfig: item.def.requiresConfig,
            )
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

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = EnvDiscovery.pathPreferringPackageManagers(env["PATH"] ?? "")
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
