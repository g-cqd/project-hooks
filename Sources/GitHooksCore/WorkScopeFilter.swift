import Foundation

/// Filters a commit list down to commits matching the branch's identifier.
///
/// Used by the work-scope feature to drop commits whose extracted identifier (typically
/// a ticket number) doesn't match the branch's. Useful when a feature branch was rebased
/// over another feature branch's commits — the ancestor work would otherwise be checked.
public enum WorkScopeFilter {
    public struct Commit: Equatable {
        public let sha: String
        public let message: String
        public let isMerge: Bool

        public init(sha: String, message: String, isMerge: Bool) {
            self.sha = sha
            self.message = message
            self.isMerge = isMerge
        }
    }

    public struct Result: Equatable {
        public let kept: [Commit]
        public let dropped: [Commit]
        /// Identifier extracted from the branch name.
        ///
        /// Nil when the branch didn't match
        /// `branchPattern` — in that case the filter is disabled and `kept == input`.
        public let branchIdentifier: String?
        /// User-facing reason the filter was disabled, if any.
        public let disabledReason: String?
        /// Set when the regex pattern itself was invalid.
        ///
        /// Caller should fail loudly.
        public let configError: String?

        public init(
            kept: [Commit],
            dropped: [Commit],
            branchIdentifier: String?,
            disabledReason: String?,
            configError: String?,
        ) {
            self.kept = kept
            self.dropped = dropped
            self.branchIdentifier = branchIdentifier
            self.disabledReason = disabledReason
            self.configError = configError
        }
    }

    /// Apply `config` to `commits`, returning the kept and dropped sets.
    ///
    /// - When `branchName` doesn't contain a match for `branchPattern`, filtering is skipped:
    ///   all commits are kept and `branchIdentifier == nil`.
    /// - When `includeMerges == true`, merge commits are always kept regardless of pattern.
    /// - A commit is kept when its message contains a `commitPattern` match equal to the branch's.
    public static func filter(
        commits: [Commit],
        branchName: String,
        config: HooksConfig.CommitFilterConfig,
    ) -> Result {
        let branchRegex: Regex<AnyRegexOutput>
        let commitRegex: Regex<AnyRegexOutput>
        do {
            branchRegex = try Regex(config.branchPattern)
            commitRegex = try Regex(config.commitPattern)
        } catch {
            return Result(
                kept: commits,
                dropped: [],
                branchIdentifier: nil,
                disabledReason: nil,
                configError: "Invalid work-scope.commit-filter pattern: \(error)",
            )
        }

        guard let branchMatch = branchName.firstMatch(of: branchRegex) else {
            return Result(
                kept: commits,
                dropped: [],
                branchIdentifier: nil,
                disabledReason: "Branch '\(branchName)' has no match for '\(config.branchPattern)'.",
                configError: nil,
            )
        }
        let branchID = String(branchName[branchMatch.range])

        var kept: [Commit] = []
        var dropped: [Commit] = []

        for commit in commits {
            if commit.isMerge, config.includeMerges {
                kept.append(commit)
                continue
            }

            let title =
                commit.message
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? commit.message

            if let match = title.firstMatch(of: commitRegex),
                String(title[match.range]) == branchID
            {
                kept.append(commit)
            } else {
                dropped.append(commit)
            }
        }

        return Result(
            kept: kept,
            dropped: dropped,
            branchIdentifier: branchID,
            disabledReason: nil,
            configError: nil,
        )
    }
}
