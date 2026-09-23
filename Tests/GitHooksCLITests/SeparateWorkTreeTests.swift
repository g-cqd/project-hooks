import Foundation
import Testing

/// From the review of the PH-5 fix: the verification worktree was created without the hook's `GIT_DIR`, so a
/// repository that works only through `GIT_DIR` and `GIT_WORK_TREE`, such as a dotfiles repository, could not push.
struct SeparateWorkTreeTests {
    @Test
    func `a repository with a separate work tree can push`() throws {
        let scratch = try ScratchRepository.make()
        defer { scratch.remove() }
        let gitDirectory = scratch.scratch.appendingPathComponent("dotfiles.git")
        let workTree = scratch.scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: workTree, withIntermediateDirectories: true)
        var environment = scratch.environment
        environment["GIT_DIR"] = gitDirectory.path
        environment["GIT_WORK_TREE"] = workTree.path
        let git = { (arguments: [String]) throws -> String in
            let run = try runProcess(["git"] + arguments, in: workTree, environment: environment)
            guard run.exitCode == 0 else { throw ScratchFailure.command(arguments, run.output) }
            return run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let marker = scratch.scratch.appendingPathComponent("task-ran").path
        _ = try runProcess(
            ["git", "init", "-q", "--bare", gitDirectory.path],
            in: scratch.scratch,
            environment: scratch.environment,
        )
        try "pre-push:\n  tasks:\n    - name: \"Mark\"\n      run: \"touch '\(marker)'\"\n"
            .write(to: workTree.appendingPathComponent(".project-hooks.yml"), atomically: true, encoding: .utf8)
        try "settings\n".write(to: workTree.appendingPathComponent(".settings"), atomically: true, encoding: .utf8)
        _ = try git(["add", ".project-hooks.yml", ".settings"])
        _ = try git(["commit", "-q", "-m", "Add settings"])
        _ = try git(["config", "project-hooks.trusted", "true"])
        let head = try git(["rev-parse", "HEAD"])

        let push = try runProcess(
            [ProjectHooksBinary.path, "pre-push", "origin", "unused-url"],
            in: workTree,
            environment: environment,
            stdin: "refs/heads/main \(head) refs/heads/main \(ScratchRepository.zeroSHA)\n",
        )

        #expect(push.exitCode == 0, "\(push.output)")
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(try git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
    }
}
