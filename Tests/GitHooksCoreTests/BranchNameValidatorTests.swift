import GitHooksCore
import Testing

struct BranchNameValidatorTests {
    private static func config(
        pattern: String = #"^(feature|bugfix)/[a-z]+/[A-Z]+-\d+-[a-z0-9-]+$"#,
        skip: [String] = [],
    ) -> HooksConfig.BranchNameConfig {
        HooksConfig.BranchNameConfig(pattern: pattern, error: "Bad branch name", skip: skip)
    }

    @Test
    func `valid branch passes`() {
        let result = BranchNameValidator.validate(
            branchName: "feature/ios/MAIN-12345-add-login",
            config: Self.config(),
        )
        #expect(result == nil)
    }

    @Test
    func `invalid branch fails with config error`() throws {
        let result = BranchNameValidator.validate(
            branchName: "wip-stuff",
            config: Self.config(),
        )
        let failure = try #require(result)
        #expect(failure.branch == "wip-stuff")
        #expect(failure.reason == "Bad branch name")
    }

    @Test
    func `skip list bypasses validation`() {
        let result = BranchNameValidator.validate(
            branchName: "develop",
            config: Self.config(skip: ["main", "develop"]),
        )
        #expect(result == nil)
    }

    @Test
    func `skip list match is exact`() {
        // "developer" should NOT match "develop" in the skip list.
        let result = BranchNameValidator.validate(
            branchName: "developer",
            config: Self.config(skip: ["develop"]),
        )
        #expect(result != nil)
    }

    @Test
    func `whole-match semantics reject prefix matches`() {
        // Pattern allows "feature/ios/MAIN-1-foo"; "feature/ios/MAIN-1-foo-suffix-with-bad-chars!" must still fail.
        let result = BranchNameValidator.validate(
            branchName: "feature/ios/MAIN-1-foo!",
            config: Self.config(),
        )
        #expect(result != nil)
    }

    @Test
    func `invalid regex surfaces config failure`() throws {
        let result = BranchNameValidator.validate(
            branchName: "anything",
            config: Self.config(pattern: "[unbalanced"),
        )
        let failure = try #require(result)
        #expect(failure.branch == "config")
        #expect(failure.reason.contains("Invalid"))
    }

    @Test
    func `shortBranchName strips refs heads prefix`() {
        #expect(BranchNameValidator.shortBranchName(fromRef: "refs/heads/feature/foo") == "feature/foo")
        #expect(BranchNameValidator.shortBranchName(fromRef: "develop") == "develop")
        #expect(BranchNameValidator.shortBranchName(fromRef: "refs/tags/v1") == "refs/tags/v1")
    }
}
