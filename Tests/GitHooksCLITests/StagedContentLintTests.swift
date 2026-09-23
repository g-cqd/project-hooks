import Foundation
import Testing

/// Review finding PH-3: linters read the working tree, not the staged blobs.
struct StagedContentLintTests {
    @Test
    func `an unstaged fix does not let staged violations through`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = BAD\n")
        try repository.git("add", "-A")
        try repository.write("Sources/App.swift", "let value = 1\n")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("\(repository.path)/Sources/App.swift:1:1: error: BAD content"))
    }

    @Test
    func `an unstaged violation does not block a clean staged file`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")
        try repository.write("Sources/App.swift", "let value = BAD\n")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
    }

    @Test
    func `the linters read a private copy that is removed afterwards`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])
        let input = try #require(repository.contentLinterInputs().first)

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!input.hasPrefix(repository.path))
        #expect(input.hasSuffix("/Sources/App.swift"))
        #expect(!FileManager.default.fileExists(atPath: input))
    }

    @Test
    func `git commit -a is checked against the index that it commits`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.commitAll("Add the app")
        try repository.installHooks()
        try repository.write("Sources/App.swift", "let value = BAD\n")

        let commit = try repository.gitRun("commit", "-a", "-m", "Break the app")

        #expect(commit.exitCode != 0, "\(commit.output)")
        #expect(commit.output.contains("BAD content"))
        #expect(try repository.git("log", "-1", "--format=%s") == "Add the app")
    }

    @Test
    func `a partially staged file is checked as staged`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let first = 1\nlet second = 2\n")
        try repository.commitAll("Add the app")
        try repository.installHooks()
        // Stage the first hunk only, as `git add -p` would.
        try repository.write("Sources/App.swift", "let first = 10\nlet second = 2\n")
        try repository.git("add", "Sources/App.swift")
        try repository.write("Sources/App.swift", "let first = 10\nlet second = BAD\n")

        let commit = try repository.gitRun("commit", "-m", "Change the first value")

        #expect(commit.exitCode == 0, "\(commit.output)")
        #expect(try repository.git("show", "HEAD:Sources/App.swift") == "let first = 10\nlet second = 2")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/swiftlint")))
    func `a SwiftLint configuration's parent configuration is part of the snapshot`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write("lint/base.yml", "only_rules:\n  - force_cast\n")
        try repository.write("Sources/.swiftlint.yml", "parent_config: ../lint/base.yml\n")
        // Only the parent's `only_rules` keeps the default rules, such as `identifier_name`, from reporting `v`.
        try repository.write("Sources/App.swift", "let v = 1\n")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!run.output.contains("was not found"))
    }
}
