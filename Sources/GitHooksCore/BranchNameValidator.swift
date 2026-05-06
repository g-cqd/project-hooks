import Foundation

/// Validates a branch name against a configurable regex.
public enum BranchNameValidator {
    public struct Failure: Equatable {
        public let branch: String
        public let reason: String

        public init(branch: String, reason: String) {
            self.branch = branch
            self.reason = reason
        }
    }

    /// Validate `branchName` against `config`.
    ///
    /// Returns nil when the branch is in the skip list, or when the pattern matches.
    /// Returns a Failure when the branch fails to match. An invalid regex pattern is
    /// surfaced as a Failure with `branch == "config"` (mirroring CommitMessageValidator).
    public static func validate(branchName: String, config: HooksConfig.BranchNameConfig) -> Failure? {
        // Bare-bones skip: exact-match list (e.g. "main", "develop", "HEAD").
        if config.skip.contains(branchName) {
            return nil
        }

        let regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(config.pattern)
        } catch {
            return Failure(
                branch: "config",
                reason: "Invalid branch-name pattern '\(config.pattern)': \(error)",
            )
        }

        if branchName.wholeMatch(of: regex) != nil {
            return nil
        }

        return Failure(branch: branchName, reason: config.error)
    }

    /// Strip a "refs/heads/" prefix to surface a user-facing branch name.
    /// Returns the original string if no prefix is present.
    public static func shortBranchName(fromRef ref: String) -> String {
        let prefix = "refs/heads/"
        if ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}
