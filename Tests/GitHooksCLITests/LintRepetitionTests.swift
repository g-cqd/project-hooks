import Foundation
import Testing

/// Review finding PH-12: pre-push linted again every file that the commit hook had linted, and each run stopped at the
/// first failing configuration group.
struct LintRepetitionTests {
    @Test
    func `every failing group is reported before the commit is blocked`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        try repository.write("Packages/One/Sources/One.swift", "let one = BAD\n")
        try repository.write("Packages/Two/Sources/Two.swift", "let two = BAD\n")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1)
        #expect(run.output.contains("One.swift:1:1: error: BAD content"), "\(run.output)")
        #expect(run.output.contains("Two.swift:1:1: error: BAD content"))
        #expect(run.output.contains("2 lint group(s) did not pass"))
    }

    @Test
    func `pre-push does not lint again what the commit hook linted`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        try repository.write("Packages/One/Sources/One.swift", "let one = 1\n")
        try repository.git("add", "-A")

        let commit = try repository.runProjectHooks(["pre-commit"])
        let head = try repository.commitAll("Add One")
        let push = try repository.runPrePush(localSHA: head)

        #expect(commit.exitCode == 0 && push.exitCode == 0, "\(push.output)")
        #expect(try repository.contentLinterInputs().count == 1)
        #expect(push.output.contains("1 file(s) passed SwiftLint before"))
    }

    @Test
    func `a retried commit lints only the groups that failed`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        try repository.write("Packages/One/Sources/One.swift", "let one = 1\n")
        try repository.write("Packages/Two/Sources/Two.swift", "let two = BAD\n")
        try repository.git("add", "-A")

        let failed = try repository.runProjectHooks(["pre-commit"])
        try repository.write("Packages/Two/Sources/Two.swift", "let two = 2\n")
        try repository.git("add", "-A")
        let retried = try repository.runProjectHooks(["pre-commit"])

        let linted = try repository.contentLinterInputs().map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(failed.exitCode == 1 && retried.exitCode == 0, "\(retried.output)")
        #expect(linted.sorted() == ["One.swift", "Two.swift", "Two.swift"])
    }

    @Test
    func `a changed configuration or the opt-out lints the files again`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        try repository.write("Packages/One/Sources/One.swift", "let one = 1\n")
        try repository.git("add", "-A")
        _ = try repository.runProjectHooks(["pre-commit"])
        let first = try repository.commitAll("Add One")

        try repository.write("Packages/One/.swiftlint.yml", "only_rules:\n  - force_try\n")
        let second = try repository.commitAll("Change the lint rules")
        // As a new branch, the push covers both commits: One.swift under the changed configuration.
        _ = try repository.runPrePush(localSHA: second)
        let afterChange = try repository.contentLinterInputs().count
        _ = try repository.runPrePush(localSHA: second)
        let afterRepeat = try repository.contentLinterInputs().count
        _ = try repository.runPrePush(localSHA: second, extraEnvironment: ["GITHOOKS_NO_CACHE": "1"])

        #expect(repository.exists("Packages/One/Sources/One.swift") && first != second)
        #expect(afterChange == 2)
        #expect(afterRepeat == 2)
        #expect(try repository.contentLinterInputs().count == 3)
    }

    @Test
    func `changing an external SwiftLint parent reruns lint on the same tree`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        let parent = repository.scratch.appendingPathComponent("parent.yml")
        try "only_rules:\n  - force_cast\n".write(to: parent, atomically: true, encoding: .utf8)
        try repository.write(".swiftlint.yml", "parent_config: \(parent.path)\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")

        let commit = try repository.runProjectHooks(["pre-commit"])
        let head = try repository.commitAll("Add the app")
        try "only_rules:\n  - force_try\n".write(to: parent, atomically: true, encoding: .utf8)
        let push = try repository.runPrePush(localSHA: head)

        #expect(commit.exitCode == 0 && push.exitCode == 0, "\(push.output)")
        #expect(try repository.contentLinterInputs().count == 2)
    }

    @Test
    func `a remote SwiftLint parent is never cached`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write(".swiftlint.yml", "parent_config: https://example.invalid/rules.yml\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")

        let first = try repository.runProjectHooks(["pre-commit"])
        let second = try repository.runProjectHooks(["pre-commit"])

        #expect(first.exitCode == 0 && second.exitCode == 0, "\(second.output)")
        #expect(try repository.contentLinterInputs().count == 2)
    }

    @Test
    func `a SwiftLint configuration symlinked outside the repository is never cached`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        let configuration = repository.scratch.appendingPathComponent("rules.yml")
        try "only_rules:\n  - force_cast\n".write(to: configuration, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repository.root.appendingPathComponent(".swiftlint.yml"))
        try FileManager.default.createSymbolicLink(
            at: repository.root.appendingPathComponent(".swiftlint.yml"), withDestinationURL: configuration)
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")

        let first = try repository.runProjectHooks(["pre-commit"])
        try "only_rules:\n  - force_try\n".write(to: configuration, atomically: true, encoding: .utf8)
        let second = try repository.runProjectHooks(["pre-commit"])

        #expect(first.exitCode == 0 && second.exitCode == 0, "\(second.output)")
        #expect(try repository.contentLinterInputs().count == 2)
    }

    @Test
    func `an include beyond the snapshot depth limit is never cached`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write(".swiftlint.yml", "parent_config: lint/1.yml\n")
        for level in 1...8 {
            let parent = level == 8 ? "https://example.invalid/rules.yml" : "\(level + 1).yml"
            try repository.write("lint/\(level).yml", "parent_config: \(parent)\n")
        }
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")

        let first = try repository.runProjectHooks(["pre-commit"])
        let second = try repository.runProjectHooks(["pre-commit"])

        #expect(first.exitCode == 0 && second.exitCode == 0, "\(second.output)")
        #expect(try repository.contentLinterInputs().count == 2)
    }

    /// From the review of the fix: a version manager's shim keeps its path, size and date when the version that it
    /// runs changes.
    @Test
    func `a new linter version behind the same binary lints the files again`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        try repository.write("Packages/One/Sources/One.swift", "let one = 1\n")
        try repository.git("add", "-A")

        _ = try repository.runProjectHooks(["pre-commit"])
        _ = try repository.runProjectHooks(["pre-commit"])
        try "2.0\n".write(
            to: repository.scratch.appendingPathComponent("swiftlint-version"),
            atomically: true,
            encoding: .utf8,
        )
        _ = try repository.runProjectHooks(["pre-commit"])

        #expect(try repository.contentLinterInputs().count == 2)
    }

    /// A repository with the content linter and a SwiftLint configuration in each of two packages.
    private func makeRepository(name: String = #function) throws -> ScratchRepository {
        let repository = try ScratchRepository.make(name)
        try repository.installContentLinter(configuration: "Packages/One/.swiftlint.yml")
        try repository.write("Packages/Two/.swiftlint.yml", "only_rules:\n  - force_cast\n")
        return repository
    }
}
