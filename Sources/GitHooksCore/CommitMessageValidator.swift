import Foundation

/// Validates commit messages against configurable rules.
public enum CommitMessageValidator {
    public struct Failure {
        public let sha: String
        public let title: String
        public let reason: String
    }

    /// Validate commit messages against a config-driven pattern and trailer rules.
    /// Returns a config-level failure immediately if the pattern is an invalid regex.
    public static func validate(
        commits: [(sha: String, message: String)],
        pattern: String?,
        patternError: String?,
        rejectTrailers: [String],
    ) -> [Failure] {
        // Compile regex upfront — fail loudly on invalid patterns
        let regex: Regex<AnyRegexOutput>?
        if let pattern {
            do {
                regex = try Regex(pattern)
            } catch {
                return [Failure(
                    sha: "config",
                    title: ".project-hooks.yml",
                    reason: "Invalid commit-message pattern '\(pattern)': \(error)",
                )]
            }
        } else {
            regex = nil
        }

        var failures: [Failure] = []

        for commit in commits {
            let title = commit.message
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? commit.message

            if let regex, title.prefixMatch(of: regex) == nil {
                failures.append(Failure(
                    sha: commit.sha,
                    title: title,
                    reason: patternError ?? "Commit title doesn't match pattern: \(pattern ?? "")",
                ))
            }

            for trailer in rejectTrailers where commit.message
                .split(whereSeparator: \.isNewline)
                .contains(where: { $0.hasPrefix("\(trailer):") }) {
                failures.append(Failure(
                    sha: commit.sha,
                    title: title,
                    reason: "Remove the \(trailer) trailer.",
                ))
            }
        }

        return failures
    }
}
