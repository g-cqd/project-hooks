import GitHooksCore
import Testing

struct CommitMessageValidatorTests {
    @Test
    func `valid messages pass with pattern`() {
        let commits = [
            (sha: "abc123", message: "PROJ-1234 Fix crash"),
            (sha: "def456", message: "PROJ-5678 Add feature"),
        ]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: #"^PROJ-\d{4}\s"#,
            patternError: "Need PROJ-XXXX",
            rejectTrailers: [],
        )
        #expect(failures.isEmpty)
    }

    @Test
    func `invalid message fails pattern`() {
        let commits = [(sha: "abc123", message: "fix stuff")]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: #"^PROJ-\d{4}\s"#,
            patternError: "Need PROJ-XXXX prefix",
            rejectTrailers: [],
        )
        #expect(failures.count == 1)
        #expect(failures[0].reason == "Need PROJ-XXXX prefix")
    }

    @Test
    func `nil pattern skips pattern check`() {
        let commits = [(sha: "abc123", message: "anything goes")]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: nil,
            patternError: nil,
            rejectTrailers: [],
        )
        #expect(failures.isEmpty)
    }

    @Test
    func `reject trailer detects co authored by`() {
        let commits = [
            (sha: "abc123", message: "PROJ-1234 Feature\n\nCo-authored-by: Bob <bob@test.com>")
        ]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: nil,
            patternError: nil,
            rejectTrailers: ["Co-authored-by"],
        )
        #expect(failures.count == 1)
        #expect(failures[0].reason.contains("Co-authored-by"))
    }

    @Test
    func `reject multiple trailers`() {
        let commits = [
            (sha: "abc123", message: "Fix\n\nSigned-off-by: A\nCo-authored-by: B")
        ]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: nil,
            patternError: nil,
            rejectTrailers: ["Signed-off-by", "Co-authored-by"],
        )
        #expect(failures.count == 2)
    }

    @Test
    func `both pattern and trailer can fail`() {
        let commits = [
            (sha: "abc123", message: "bad\n\nCo-authored-by: B")
        ]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: #"^PROJ-\d+"#,
            patternError: "Bad format",
            rejectTrailers: ["Co-authored-by"],
        )
        #expect(failures.count == 2)
    }

    @Test
    func `invalid regex pattern fails loudly`() {
        let commits = [(sha: "abc123", message: "anything")]
        let failures = CommitMessageValidator.validate(
            commits: commits,
            pattern: "[invalid(regex",  // broken regex — unbalanced bracket
            patternError: nil,
            rejectTrailers: [],
        )
        // Should return a config-level failure, not silently skip
        #expect(failures.count == 1)
        #expect(failures[0].sha == "config")
        #expect(failures[0].reason.contains("Invalid"))
    }
}
