import GitHooksCore
import Testing

struct WorkScopeFilterTests {
    private static func config(
        branchPattern: String = #"MAIN-\d+"#,
        commitPattern: String = #"^MAIN-\d+"#,
        onMismatch: HooksConfig.MismatchAction = .warn,
        includeMerges: Bool = true,
    ) -> HooksConfig.CommitFilterConfig {
        HooksConfig.CommitFilterConfig(
            branchPattern: branchPattern,
            commitPattern: commitPattern,
            onMismatch: onMismatch,
            includeMerges: includeMerges,
        )
    }

    private static func commit(_ sha: String, _ message: String, isMerge: Bool = false) -> WorkScopeFilter.Commit {
        WorkScopeFilter.Commit(sha: sha, message: message, isMerge: isMerge)
    }

    @Test
    func `keeps commits matching branch ticket`() {
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 first"),
                Self.commit("b", "MAIN-12345 second"),
            ],
            branchName: "feature/ios/MAIN-12345-blah",
            config: Self.config(),
        )
        #expect(result.kept.count == 2)
        #expect(result.dropped.isEmpty)
        #expect(result.branchIdentifier == "MAIN-12345")
    }

    @Test
    func `drops commits with different ticket`() {
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 mine"),
                Self.commit("b", "MAIN-99999 someone elses"),
            ],
            branchName: "feature/ios/MAIN-12345-blah",
            config: Self.config(),
        )
        #expect(result.kept.map(\.sha) == ["a"])
        #expect(result.dropped.map(\.sha) == ["b"])
    }

    @Test
    func `drops commits without any ticket`() {
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 mine"),
                Self.commit("b", "WIP fixup"),
            ],
            branchName: "feature/ios/MAIN-12345-blah",
            config: Self.config(),
        )
        #expect(result.kept.map(\.sha) == ["a"])
        #expect(result.dropped.map(\.sha) == ["b"])
    }

    @Test
    func `keeps merges by default even if message has no ticket`() {
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 mine"),
                Self.commit("m", "Merge branch 'develop' into feature/ios/MAIN-12345-blah", isMerge: true),
            ],
            branchName: "feature/ios/MAIN-12345-blah",
            config: Self.config(),
        )
        #expect(result.kept.map(\.sha) == ["a", "m"])
    }

    @Test
    func `include-merges false treats merges like normal commits`() {
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 mine"),
                Self.commit("m", "Merge branch 'develop' into feature/...", isMerge: true),
            ],
            branchName: "feature/ios/MAIN-12345-blah",
            config: Self.config(includeMerges: false),
        )
        #expect(result.kept.map(\.sha) == ["a"])
        #expect(result.dropped.map(\.sha) == ["m"])
    }

    @Test
    func `branch without ticket disables filter`() {
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 something"),
                Self.commit("b", "WIP"),
            ],
            branchName: "develop",
            config: Self.config(),
        )
        #expect(result.kept.count == 2)
        #expect(result.branchIdentifier == nil)
        #expect(result.disabledReason != nil)
    }

    @Test
    func `invalid regex surfaces config error and keeps all`() {
        let result = WorkScopeFilter.filter(
            commits: [Self.commit("a", "MAIN-1 x")],
            branchName: "feature/MAIN-1-blah",
            config: Self.config(branchPattern: "[broken"),
        )
        #expect(result.configError != nil)
        #expect(result.kept.count == 1)
    }

    @Test
    func `commit pattern matches title not body`() {
        // Body mentions another ticket, but title doesn't.
        let result = WorkScopeFilter.filter(
            commits: [
                Self.commit("a", "MAIN-12345 mine\n\nRelated: MAIN-99999"),
            ],
            branchName: "feature/ios/MAIN-12345-blah",
            config: Self.config(),
        )
        #expect(result.kept.map(\.sha) == ["a"])
    }
}
