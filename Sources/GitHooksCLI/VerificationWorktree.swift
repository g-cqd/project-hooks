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

    /// Check out `commit` in a new detached worktree at `path`, with its submodules.
    ///
    /// A worktree that an earlier run left at `path`, for example when it was killed, is removed first. Callers keep
    /// `path` stable for a repository, so that builds see the same source paths from one push to the next, and hold
    /// the repository's lock while the worktree exists.
    static func create(commit: String, repoRoot: String, path: String) throws -> VerificationWorktree {
        let worktree = VerificationWorktree(path: path, commit: commit)
        if FileManager.default.fileExists(atPath: path) {
            worktree.remove(repoRoot: repoRoot)
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        do {
            try worktree.inScope {
                // No hook runs for this checkout, so creating it cannot start another verification.
                try worktree.git(
                    [
                        "-c",
                        "core.hooksPath=/dev/null",
                        "worktree",
                        "add",
                        "--detach",
                        "--force",
                        "--quiet",
                        path,
                        commit,
                    ],
                    in: repoRoot,
                )
                if FileManager.default.fileExists(atPath: "\(path)/.gitmodules") {
                    try worktree.git(["submodule", "update", "--init", "--recursive", "--quiet"], in: path)
                }
            }
        } catch {
            worktree.remove(repoRoot: repoRoot)
            throw error
        }
        return worktree
    }

    /// Run `body` with the environment for commands in this worktree.
    func inScope<Result>(_ body: () throws -> Result) rethrows -> Result {
        try CommandScope.$removedVariables.withValue(Self.repositoryVariables, operation: body)
    }

    /// Remove the worktree and its registration, even after an interruption.
    ///
    /// Failures are reported, not thrown, so that they cannot replace the verification's own outcome.
    func remove(repoRoot: String) {
        inScope {
            do {
                try git(["worktree", "remove", "--force", "--force", path], in: repoRoot, interruptible: false)
            } catch {
                // Not registered, or not removable: remove the directory, then forget any registration.
                try? FileManager.default.removeItem(atPath: path)
                _ = try? runCommand(["git", "worktree", "prune"], currentDirectory: repoRoot, interruptible: false)
                if FileManager.default.fileExists(atPath: path) {
                    printWarn("Could not remove the worktree at \(path): \(error)")
                }
            }
        }
    }

    private func git(_ arguments: [String], in directory: String, interruptible: Bool = true) throws {
        let result = try runCommand(
            ["git"] + arguments,
            currentDirectory: directory,
            timeoutSeconds: 600,
            interruptible: interruptible,
        )
        guard result.exitCode == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("git \(arguments.joined(separator: " ")) failed: \(stderr)")
        }
    }
}
