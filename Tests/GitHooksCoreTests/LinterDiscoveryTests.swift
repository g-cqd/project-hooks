import Foundation
import GitHooksCore
import Testing

struct LinterDiscoveryTests {
    @Test
    func `filter files for IOS`() {
        let files = ["App.swift", "README.md", "build.gradle", "Tests.kt"]
        let filtered = LinterDiscovery.filterFiles(files, forPlatform: .ios)
        #expect(filtered == ["App.swift"])
    }

    @Test
    func `filter files for android`() {
        let files = ["App.swift", "README.md", "Main.kt", "Settings.kts", "Helper.java"]
        let filtered = LinterDiscovery.filterFiles(files, forPlatform: .android)
        #expect(filtered == ["Main.kt", "Settings.kts", "Helper.java"])
    }

    @Test
    func `filter files for mixed`() {
        let files = ["App.swift", "Main.kt"]
        let filtered = LinterDiscovery.filterFiles(files, forPlatform: .mixed)
        #expect(filtered == ["App.swift", "Main.kt"])
    }

    @Test
    func `filter files for unknown`() {
        let files = ["App.swift", "Main.kt"]
        let filtered = LinterDiscovery.filterFiles(files, forPlatform: .unknown)
        #expect(filtered.isEmpty)
    }

    @Test
    func `file extensions for platforms`() {
        #expect(LinterDiscovery.fileExtensions(for: .ios) == [".swift"])
        #expect(LinterDiscovery.fileExtensions(for: .android) == [".kt", ".kts", ".java"])
        #expect(LinterDiscovery.fileExtensions(for: .mixed) == [".swift", ".kt", ".kts", ".java"])
        #expect(LinterDiscovery.fileExtensions(for: .unknown).isEmpty)
    }

    @Test
    func `known IOS linters have expected entries`() {
        #expect(LinterDiscovery.knownIOSLinters.contains("SwiftLint"))
        #expect(LinterDiscovery.knownIOSLinters.contains("SwiftFormat"))
        #expect(LinterDiscovery.knownIOSLinters.contains("swift-format"))
    }

    @Test
    func `known android linters have expected entries`() {
        #expect(LinterDiscovery.knownAndroidLinters.contains("ktlint"))
        #expect(LinterDiscovery.knownAndroidLinters.contains("detekt"))
    }

    @Test
    func `discover linters for unknown platform returns empty`() {
        let linters = LinterDiscovery.discoverLinters(
            forPlatform: .unknown,
            repoRoot: "/tmp/nonexistent",
        )
        #expect(linters.isEmpty)
    }

    @Test
    func `discovered linter paths have no trailing newlines`() {
        // Regression: resolveExecutable used to return paths with trailing newlines
        // due to operator precedence bug: `String(...) ?? "".trimming(...)` trims
        // the empty string, not the result.
        let linters = LinterDiscovery.discoverLinters(
            forPlatform: .ios,
            repoRoot: "/tmp/nonexistent",
        )
        for linter in linters {
            #expect(!linter.executablePath.contains("\n"))
            #expect(linter.executablePath == linter.executablePath.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - requiresConfig

    @Test
    func `all linters require config`() {
        let linters = LinterDiscovery.discoverLinters(
            forPlatform: .ios,
            repoRoot: "/tmp/nonexistent",
        )
        for linter in linters {
            #expect(linter.requiresConfig, "Expected \(linter.name) to require config")
        }
    }

    // MARK: - usesSwiftSubcommand

    @Test
    func `discovered linter defaults usesSwiftSubcommand to false`() {
        let linter = DiscoveredLinter(
            name: "SwiftLint",
            executablePath: "/usr/bin/swiftlint",
            configCandidates: [".swiftlint.yml"],
            platform: .ios,
        )
        #expect(!linter.usesSwiftSubcommand)
    }

    @Test
    func `discovered linter can set usesSwiftSubcommand`() {
        let linter = DiscoveredLinter(
            name: "swift-format",
            executablePath: "/usr/bin/swift",
            configCandidates: [".swift-format"],
            platform: .ios,
            usesSwiftSubcommand: true,
        )
        #expect(linter.usesSwiftSubcommand)
    }

    @Test
    func `swift format falls back to swift subcommand when standalone binary not found`() {
        let linters = LinterDiscovery.discoverLinters(
            forPlatform: .ios,
            repoRoot: "/tmp/nonexistent",
        )
        // swift-format should always be discovered (via swift binary fallback)
        let swiftFormat = linters.first(where: { $0.name == "swift-format" })
        #expect(swiftFormat != nil, "swift-format should be discovered via swift binary fallback")
        if let sf = swiftFormat, sf.usesSwiftSubcommand {
            #expect(sf.executablePath.hasSuffix("swift"))
        }
    }
}
