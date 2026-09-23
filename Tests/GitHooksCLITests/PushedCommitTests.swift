import Foundation
import Testing

/// Review finding PH-5: pre-push linted and tested the working tree, not the commits that the push sends.
struct PushedCommitTests {
    @Test
    func `a branch that is not checked out is linted as pushed`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.commitAll("Add the app")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.write("Sources/App.swift", "let value = BAD\n")
        let feature = try repository.commitAll("Break the app on a branch")
        try repository.git("checkout", "-q", "main")

        let run = try repository.runPrePush(branch: "feature", localSHA: feature)

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("\(repository.path)/Sources/App.swift:1:1: error: BAD content"))
    }

    @Test
    func `uncommitted changes neither block nor excuse a push`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = 1\n")
        let good = try repository.commitAll("Add the app")
        try repository.write("Sources/App.swift", "let value = BAD\n")

        let goodPush = try repository.runPrePush(localSHA: good)
        let bad = try repository.commitAll("Break the app")
        try repository.write("Sources/App.swift", "let value = 2\n")
        let badPush = try repository.runPrePush(localSHA: bad)

        #expect(goodPush.exitCode == 0, "\(goodPush.output)")
        #expect(badPush.exitCode == 1, "\(badPush.output)")
    }

    @Test
    func `each distinct pushed commit is checked`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter()
        try repository.write("Sources/App.swift", "let value = 1\n")
        let main = try repository.commitAll("Add the app")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.write("Sources/Feature.swift", "let feature = BAD\n")
        let feature = try repository.commitAll("Add a broken feature")
        try repository.git("checkout", "-q", "main")

        let run = try repository.runProjectHooks(
            ["pre-push", "origin", "unused-url"],
            stdin: """
                refs/heads/main \(main) refs/heads/main \(ScratchRepository.zeroSHA)
                refs/heads/feature \(feature) refs/heads/feature \(ScratchRepository.zeroSHA)
                refs/heads/also-main \(main) refs/heads/also-main \(ScratchRepository.zeroSHA)

                """,
        )

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("Commit \(main.prefix(10)) (main, also-main)"))
        #expect(run.output.contains("Commit \(feature.prefix(10)) (feature)"))
        #expect(run.output.contains("Feature.swift:1:1: error: BAD content"))
    }

    @Test
    func `s run in a clean checkout of the pushed commit, which is removed afterwards`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let log = repository.scratch.appendingPathComponent("test-runs")
        try repository.write(".project-hooks.yml", "pre-push:\n  test-override:\n    type: gradle\n")
        try repository.write(
            "gradlew",
            "#!/bin/sh\n{ pwd -P; git rev-parse HEAD; cat marker.txt; } >> '\(log.path)'\n",
            executable: true,
        )
        try repository.write("marker.txt", "pushed content\n")
        let pushed = try repository.commitAll("Add a test runner")
        try repository.addOrigin()
        try repository.trust()
        try repository.installHooks()
        // Push `main` from a linked worktree on another branch: git sets GIT_DIR to that worktree for the hook.
        let other = repository.scratch.appendingPathComponent("other")
        try repository.git("worktree", "add", "-q", "-b", "other", other.path)
        try "other content\n".write(to: other.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try repository.gitRun("commit", "-q", "--no-verify", "-am", "Change the marker", in: other)
        try "uncommitted content\n".write(
            to: repository.root.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8,
        )

        let push = try repository.gitRun("push", "-q", "origin", "main", in: other)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)

        #expect(push.exitCode == 0, "\(push.output)")
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.first != repository.path && lines.first != other.path)
        #expect(lines.dropFirst().first == pushed)
        #expect(lines.last == "pushed content")
        #expect(try repository.worktreePaths() == [repository.path, other.path])
        #expect(lines.first.map { FileManager.default.fileExists(atPath: $0) } == false)
    }
}
