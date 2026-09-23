import Foundation
import Testing

/// Review finding PH-1: every non-zero SwiftLint exit read as violations, and excluded files were linted.
struct LinterExitCodeTests {
    @Test
    func `a group whose files are all excluded passes`() throws {
        let repository =
            try makeRepository(fakeSwiftLint: "echo \"Error: No lintable files found at paths: ''\" >&2\nexit 1")
        defer { repository.remove() }

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!run.output.contains("reported violations"))
    }

    @Test
    func `a SwiftLint usage error blocks as a failure to run, not as violations`() throws {
        let repository = try makeRepository(fakeSwiftLint: "echo \"Error: Unknown option\" >&2\nexit 64")
        defer { repository.remove() }

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1)
        #expect(run.output.contains("SwiftLint failed to run (exit 64)"), "\(run.output)")
        #expect(!run.output.contains("reported violations"))
    }

    @Test
    func `SwiftLint violations still block`() throws {
        let repository = try makeRepository(fakeSwiftLint: "exit 2")
        defer { repository.remove() }

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1)
        #expect(run.output.contains("SwiftLint reported violations"), "\(run.output)")
    }

    @Test
    func `SwiftLint applies its exclusions to the files it is given`() throws {
        let repository = try makeRepository(fakeSwiftLint: "exit 0")
        defer { repository.remove() }

        _ = try repository.runProjectHooks(["pre-commit"])

        let arguments = try String(
            contentsOf: repository.scratch.appendingPathComponent("swiftlint-arguments"),
            encoding: .utf8,
        )
        #expect(arguments.split(separator: "\n").contains("--force-exclude"), "\(arguments)")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/swiftlint")))
    func `real SwiftLint skips an excluded file and still lints the others`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        try repository.write(".swiftlint.yml", "excluded:\n  - Tests\nonly_rules:\n  - force_cast\n")
        try repository.write("Tests/Excluded.swift", "let value = input as! Int\n")
        try repository.git("add", "-A")

        let excludedOnly = try repository.runProjectHooks(["pre-commit"])
        try repository.write("Sources/Linted.swift", "let value = input as! Int\n")
        try repository.git("add", "-A")
        let withLintedFile = try repository.runProjectHooks(["pre-commit"])

        #expect(excludedOnly.exitCode == 0, "\(excludedOnly.output)")
        #expect(withLintedFile.exitCode == 1, "\(withLintedFile.output)")
        #expect(withLintedFile.output.contains("Linted.swift"))
        #expect(!withLintedFile.output.contains("Excluded.swift:1"))
    }

    /// A repository with a SwiftLint configuration and a staged Swift file, where `swiftlint` is a fake that records
    /// its arguments and then runs `body`.
    private func makeRepository(fakeSwiftLint body: String, name: String = #function) throws -> ScratchRepository {
        let repository = try ScratchRepository.make(name)
        let log = repository.scratch.appendingPathComponent("swiftlint-arguments").path
        try repository.installTool("swiftlint", script: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(log)'\n\(body)\n")
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        try repository.write(".swiftlint.yml", "only_rules:\n  - force_cast\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")
        return repository
    }
}
