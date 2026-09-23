import Foundation
import GitHooksCore

/// A temporary linked worktree at a commit that is being pushed, where that commit's tasks, builds and tests run.
///
/// The working tree can hold another branch, or uncommitted changes, so running them there would check something
/// other than what the push sends.
struct VerificationWorktree {
    let path: String
    let commit: String

    /// Variables that make git use a particular repository, index or working tree, as `git rev-parse --local-env-vars`
    /// lists them.
    ///
    /// Git sets some of them for hooks, such as `GIT_DIR` when the push starts in a linked worktree, so the commands in
    /// the verification worktree run without them.
    static let repositoryVariables: Set<String> = {
        let fallback: Set = [
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
            "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
            "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
            "GIT_COMMON_DIR",
        ]
        guard let result = try? runCommand(["git", "rev-parse", "--local-env-vars"]), result.exitCode == 0 else {
            return fallback
        }
        return fallback.union(result.stdoutText.split(whereSeparator: \.isNewline).map(String.init))
    }()

    /// Check out `commit` in a new detached worktree of the repository at `repoRoot`, with its submodules.
    static func create(commit: String, repoRoot: String) throws -> VerificationWorktree {
        let path =
            canonicalPath(FileManager.default.temporaryDirectory.path)
            + "/project-hooks-push-\(commit.prefix(12))-\(UUID().uuidString.prefix(8))"
        let worktree = VerificationWorktree(path: path, commit: commit)
        try worktree.inScope {
            // No hook runs for this checkout, so creating it cannot start another verification.
            try worktree.git(
                ["-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", "--quiet", path, commit],
                in: repoRoot,
            )
            if FileManager.default.fileExists(atPath: "\(path)/.gitmodules") {
                do {
                    try worktree.git(["submodule", "update", "--init", "--recursive", "--quiet"], in: path)
                } catch {
                    worktree.remove(repoRoot: repoRoot)
                    throw error
                }
            }
        }
        return worktree
    }

    /// Run `body` with the environment for commands in this worktree.
    func inScope<Result>(_ body: () throws -> Result) rethrows -> Result {
        try CommandScope.$removedVariables.withValue(Self.repositoryVariables, operation: body)
    }

    /// Remove the worktree and its registration.
    ///
    /// Removal failures are reported, not thrown, so that they cannot replace the verification's own outcome.
    func remove(repoRoot: String) {
        inScope {
            do {
                try git(["worktree", "remove", "--force", "--force", path], in: repoRoot)
            } catch {
                printWarn("Could not remove the worktree at \(path): \(error). Removing its directory instead.")
                try? FileManager.default.removeItem(atPath: path)
                _ = try? runCommand(["git", "worktree", "prune"], currentDirectory: repoRoot)
            }
        }
    }

    private func git(_ arguments: [String], in directory: String) throws {
        let result = try runCommand(["git"] + arguments, currentDirectory: directory, timeoutSeconds: 600)
        guard result.exitCode == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("git \(arguments.joined(separator: " ")) failed: \(stderr)")
        }
    }
}
