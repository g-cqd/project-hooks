import Foundation

/// The user's decision to let project-hooks run a repository's own code: its custom tasks, its builds and tests, and
/// linters that it builds itself.
///
/// The decision lives in git configuration under `project-hooks.trusted`. `project-hooks trust` writes it to the
/// repository's local configuration, which a clone never copies, so a repository cannot trust itself. Any other
/// scope works too, for example a global `includeIf` that trusts every repository in a directory.
enum RepositoryTrust {
    static let configKey = "project-hooks.trusted"

    /// Whether `project-hooks.trusted` is true for the repository at `repoRoot`.
    ///
    /// A missing key means untrusted. An invalid value also means untrusted, with a warning.
    static func isTrusted(repoRoot: String) throws -> Bool {
        let result = try runCommand(
            ["git", "config", "--type=bool", "--get", configKey],
            currentDirectory: repoRoot,
        )
        switch result.exitCode {
            case 0:
                return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            case 1:
                return false
            default:
                let reason = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                printWarn("Ignoring \(configKey): \(reason)")
                return false
        }
    }

    /// Record or revoke trust in the repository's local git configuration.
    static func setTrusted(_ trusted: Bool, repoRoot: String) throws {
        let arguments =
            trusted
            ? ["git", "config", "--local", "--type=bool", configKey, "true"]
            : ["git", "config", "--local", "--unset-all", configKey]
        let result = try runCommand(arguments, currentDirectory: repoRoot)
        // `--unset-all` exits 5 when the key is already absent.
        guard result.exitCode == 0 || (!trusted && result.exitCode == 5) else {
            let reason = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("git config failed: \(reason)")
        }
    }

    /// Say that a step which runs the repository's own code did not run, and how to trust the repository.
    static func reportSkipped(_ step: String) {
        printWarn("Skipped \(step): this repository is not trusted to run its own code.")
        printInfo("To trust this repository, run: project-hooks trust")
    }
}
