import Darwin
import Foundation
import Testing

@testable import GitHooksCLI

/// Review finding PH-7: Ctrl-C ended the hook at once, leaving its build running and its temporary checkouts behind.
struct InterruptionTests {
    @Test
    func `an interrupted push stops its tests and removes its worktree`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let handshake = try Handshake(in: repository.scratch)
        defer { handshake.release() }
        try repository.installTool("swift", script: handshake.blockingScript)
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        let head = try repository.commitAll("Add the app")
        try repository.trust()

        let hook = try repository.startProjectHooks(
            ["pre-push", "origin", "unused-url"],
            stdin: "refs/heads/main \(head) refs/heads/main \(ScratchRepository.zeroSHA)\n",
        )
        let testsPID = try handshake.waitUntilStarted()
        kill(hook.processIdentifier, SIGINT)
        hook.waitUntilExit()

        #expect(hook.terminationReason == .exit)
        #expect(hook.terminationStatus == 128 + SIGINT)
        #expect(kill(testsPID, 0) == -1, "the tests were stopped")
        #expect(try repository.worktreePaths() == [repository.path])
        let worktrees = repository.cacheDirectory.appendingPathComponent("worktrees").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? []).isEmpty)
    }

    @Test
    func `a push that waits for another run in the repository can be interrupted`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", "pre-push:\n  test-override:\n    type: gradle\n")
        try repository.write("gradlew", "#!/bin/sh\nexit 0\n", executable: true)
        let head = try repository.commitAll("Add a test runner")
        try repository.trust()
        let key = try HookCache.repositoryKey(repoRoot: repository.path)
        let otherRun = try FileLock(path: repository.cacheDirectory.appendingPathComponent("locks/\(key).lock").path)
        let output = Pipe()

        let hook = try repository.startProjectHooks(
            ["pre-push", "origin", "unused-url"],
            stdin: "refs/heads/main \(head) refs/heads/main \(ScratchRepository.zeroSHA)\n",
            output: output,
            deadline: 60,
        )
        var printed = ""
        while !printed.contains("Waiting for another project-hooks run") {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            printed += String(decoding: chunk, as: UTF8.self)
        }
        kill(hook.processIdentifier, SIGINT)
        hook.waitUntilExit()
        _ = consume otherRun

        #expect(printed.contains("Waiting for another project-hooks run"), "\(printed)")
        #expect(hook.terminationReason == .exit)
        #expect(hook.terminationStatus == 128 + SIGINT)
    }

    @Test
    func `an interrupted commit removes its snapshot`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let handshake = try Handshake(in: repository.scratch)
        defer { handshake.release() }
        let inputs = repository.scratch.appendingPathComponent("inputs")
        try repository.installTool(
            "swiftlint",
            script: handshake.blockingScript.replacingOccurrences(
                of: "echo $$",
                with: "echo \"$SCRIPT_INPUT_FILE_0\" > '\(inputs.path)'\necho $$",
            ),
        )
        try repository.write(".swiftlint.yml", "only_rules:\n  - force_cast\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")

        let hook = try repository.startProjectHooks(["pre-commit"])
        _ = try handshake.waitUntilStarted()
        kill(hook.processIdentifier, SIGINT)
        hook.waitUntilExit()
        let snapshotFile = try String(contentsOf: inputs, encoding: .utf8).trimmingCharacters(in: .newlines)

        #expect(hook.terminationStatus == 128 + SIGINT)
        #expect(!snapshotFile.hasPrefix(repository.path))
        #expect(!FileManager.default.fileExists(atPath: snapshotFile))
    }
}

/// Two named pipes that let a test know, without polling, that a fake tool has started, and keep the tool blocked
/// until something stops it.
private struct Handshake {
    let started: String
    let hold: String

    init(in directory: URL) throws {
        started = directory.appendingPathComponent("started.fifo").path
        hold = directory.appendingPathComponent("hold.fifo").path
        guard mkfifo(started, 0o600) == 0, mkfifo(hold, 0o600) == 0 else {
            throw ScratchFailure.command(["mkfifo"], String(cString: strerror(errno)))
        }
    }

    /// A tool that answers `--version` at once, and otherwise reports its process identifier, then blocks until it is
    /// killed or released.
    var blockingScript: String {
        """
        #!/bin/sh
        [ "$1" = "--version" ] && echo "fake 1.0" && exit 0
        echo $$ > '\(started)'
        read line < '\(hold)'

        """
    }

    /// Block until the tool has started, and return its process identifier.
    func waitUntilStarted() throws -> pid_t {
        // Opening the pipe blocks until the tool opens it, and reading returns once the tool has written and closed it.
        guard let pipe = FileHandle(forReadingAtPath: started) else {
            throw ScratchFailure.command(["open", started], "cannot open")
        }
        defer { try? pipe.close() }
        let text = String(decoding: pipe.readDataToEndOfFile(), as: UTF8.self)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Unblock a tool that nothing stopped, so that no process outlives the test.
    func release() {
        let descriptor = open(hold, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return }
        _ = write(descriptor, "\n", 1)
        close(descriptor)
    }
}
