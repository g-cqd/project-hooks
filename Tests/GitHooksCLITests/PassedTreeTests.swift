import Foundation
import Testing

/// Review finding PH-8: nothing remembered a tree that already passed, so pushing it again ran every test again.
struct PassedTreeTests {
    @Test
    func `pushing a tree that passed skips its tests, even under another commit`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        let first = try repository.commitAll("Add the app")

        let firstPush = try repository.runPrePush(localSHA: first)
        let secondRemote = try repository.runPrePush(localSHA: first)
        try repository.git("commit", "-q", "--amend", "--no-verify", "-m", "Add the app, reworded")
        let reworded = try repository.git("rev-parse", "HEAD")
        let rewordedPush = try repository.runPrePush(localSHA: reworded)

        #expect(firstPush.exitCode == 0 && secondRemote.exitCode == 0 && rewordedPush.exitCode == 0)
        #expect(try testRuns(in: repository) == 1)
        #expect(secondRemote.output.contains("passed on this tree before"), "\(secondRemote.output)")
        #expect(rewordedPush.output.contains("passed on this tree before"))
    }

    @Test
    func `a different tree, command or opt-out runs the tests again`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        let first = try repository.commitAll("Add the app")
        _ = try repository.runPrePush(localSHA: first)

        try repository.write("Sources/App.swift", "let value = 2\n")
        let changed = try repository.commitAll("Change the app")
        _ = try repository.runPrePush(localSHA: changed, remoteSHA: first)
        // The configuration comes from the working tree, so this changes the command but not the tree.
        try repository.write(
            ".project-hooks.yml",
            "pre-push:\n  test-override:\n    type: gradle\n    extra-args: [\"--offline\"]\n",
        )
        _ = try repository.runPrePush(localSHA: changed, remoteSHA: first)
        _ = try repository.runPrePush(localSHA: changed, remoteSHA: first, extraEnvironment: ["GITHOOKS_NO_CACHE": "1"])

        #expect(try testRuns(in: repository) == 4)
    }

    @Test
    func `a failing run is not remembered`() throws {
        let repository = try makeRepository(testsFailWhilePresent: "tests-fail")
        defer { repository.remove() }
        let head = try repository.commitAll("Add the app")
        FileManager.default.createFile(
            atPath: repository.scratch.appendingPathComponent("tests-fail").path,
            contents: nil,
        )

        let failing = try repository.runPrePush(localSHA: head)
        try FileManager.default.removeItem(at: repository.scratch.appendingPathComponent("tests-fail"))
        let passing = try repository.runPrePush(localSHA: head)

        #expect(failing.exitCode == 1)
        #expect(passing.exitCode == 0, "\(passing.output)")
        #expect(try testRuns(in: repository) == 2)
    }

    /// A trusted repository whose Gradle test override logs each run outside the repository, and fails while
    /// `testsFailWhilePresent` exists in the scratch directory.
    private func makeRepository(testsFailWhilePresent marker: String = "never", name: String = #function) throws
        -> ScratchRepository
    {
        let repository = try ScratchRepository.make(name)
        let log = repository.scratch.appendingPathComponent("test-runs").path
        let failure = repository.scratch.appendingPathComponent(marker).path
        try repository.write(".project-hooks.yml", "pre-push:\n  test-override:\n    type: gradle\n")
        try repository.write(
            "gradlew",
            "#!/bin/sh\necho run >> '\(log)'\n[ ! -e '\(failure)' ]\n",
            executable: true,
        )
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.trust()
        return repository
    }

    private func testRuns(in repository: ScratchRepository) throws -> Int {
        let log = repository.scratch.appendingPathComponent("test-runs")
        guard FileManager.default.fileExists(atPath: log.path) else { return 0 }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
    }
}
