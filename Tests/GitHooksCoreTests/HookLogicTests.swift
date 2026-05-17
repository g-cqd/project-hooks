import Foundation
import GitHooksCore
import Testing

struct HookLogicTests {
    @Test
    func `parse push updates parses valid rows`() throws {
        let stdin = "refs/heads/feature abc refs/heads/feature def\nrefs/heads/main 111 refs/heads/main 222\n"
        let updates = HookLogic.parsePushUpdates(from: stdin)

        #expect(updates.count == 2)
        let first = try #require(updates.first)
        #expect(
            first
                == GitPushUpdate(
                    localRef: "refs/heads/feature",
                    localSHA: "abc",
                    remoteRef: "refs/heads/feature",
                    remoteSHA: "def",
                ))
    }

    @Test
    func `parse push updates ignores malformed rows`() throws {
        let stdin = "\ninvalid\nrefs/heads/main 111 refs/heads/main\nrefs/heads/fix aaa refs/heads/fix bbb\n"
        let updates = HookLogic.parsePushUpdates(from: stdin)

        #expect(updates.count == 1)
        let first = try #require(updates.first)
        #expect(first.localRef == "refs/heads/fix")
    }

    @Test
    func `parse push updates handles CRLF`() throws {
        let stdin = "refs/heads/main abc refs/heads/main def\r\n"
        let updates = HookLogic.parsePushUpdates(from: stdin)

        #expect(updates.count == 1)
        let first = try #require(updates.first)
        #expect(first.remoteSHA == "def")
    }

    @Test
    func `git push update computed properties`() {
        let zeroSHA = String(repeating: "0", count: 40)

        let tagUpdate = GitPushUpdate(
            localRef: "refs/tags/v1.0.0", localSHA: "abc",
            remoteRef: "refs/tags/v1.0.0", remoteSHA: "def",
        )
        #expect(tagUpdate.isTagUpdate)

        let deletion = GitPushUpdate(
            localRef: "refs/heads/feature", localSHA: zeroSHA,
            remoteRef: "refs/heads/feature", remoteSHA: "def",
        )
        #expect(deletion.isDeletion)

        let newRemote = GitPushUpdate(
            localRef: "refs/heads/feature", localSHA: "abc",
            remoteRef: "refs/heads/feature", remoteSHA: zeroSHA,
        )
        #expect(newRemote.isNewRemoteRef)
    }

    @Test
    func `is zero SHA`() {
        #expect(HookLogic.isZeroSHA(String(repeating: "0", count: 40)))
        #expect(!HookLogic.isZeroSHA("abc123"))
        #expect(!HookLogic.isZeroSHA(""))
    }

    @Test
    func `is valid git SHA`() {
        #expect(HookLogic.isValidGitSHA(String(repeating: "a", count: 40)))
        #expect(!HookLogic.isValidGitSHA(String(repeating: "a", count: 39)))
        #expect(!HookLogic.isValidGitSHA("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
    }

    @Test
    func `should skip update returns true for tags`() {
        let update = GitPushUpdate(
            localRef: "refs/tags/v1.0.0", localSHA: "abc",
            remoteRef: "refs/tags/v1.0.0", remoteSHA: "def",
        )
        #expect(HookLogic.shouldSkipUpdate(update))
    }

    @Test
    func `should skip update returns true for deletions`() {
        let zeroSHA = String(repeating: "0", count: 40)
        let update = GitPushUpdate(
            localRef: "refs/heads/feature", localSHA: zeroSHA,
            remoteRef: "refs/heads/feature", remoteSHA: "abc",
        )
        #expect(HookLogic.shouldSkipUpdate(update))
    }

    @Test
    func `should skip update returns false for normal push`() {
        let sha1 = String(repeating: "a", count: 40)
        let sha2 = String(repeating: "b", count: 40)
        let update = GitPushUpdate(
            localRef: "refs/heads/main", localSHA: sha1,
            remoteRef: "refs/heads/main", remoteSHA: sha2,
        )
        #expect(!HookLogic.shouldSkipUpdate(update))
    }

    @Test
    func `validate update SHAs accepts valid SHAs`() {
        let sha1 = String(repeating: "a", count: 40)
        let sha2 = String(repeating: "b", count: 40)
        let update = GitPushUpdate(
            localRef: "refs/heads/main", localSHA: sha1,
            remoteRef: "refs/heads/main", remoteSHA: sha2,
        )
        #expect(HookLogic.validateUpdateSHAs(update) == nil)
    }

    @Test
    func `validate update SHAs rejects short SHA`() {
        let update = GitPushUpdate(
            localRef: "refs/heads/main", localSHA: "abc123",
            remoteRef: "refs/heads/main", remoteSHA: String(repeating: "b", count: 40),
        )
        #expect(HookLogic.validateUpdateSHAs(update) != nil)
    }

    @Test
    func `tag push with short SHAs is skipped before validation`() {
        let update = GitPushUpdate(
            localRef: "refs/tags/v1.0.0", localSHA: "abc",
            remoteRef: "refs/tags/v1.0.0", remoteSHA: "def",
        )
        if !HookLogic.shouldSkipUpdate(update) {
            Issue.record("Tag should have been skipped")
        }
    }

    // MARK: - XCTestPlan parsing

    @Test
    func `parse bundles from xctestplan data`() {
        let json = """
            {
              "testTargets": [
                { "target": { "identifier": "UUID123", "name": "UnitTests" } },
                { "target": { "identifier": "UITests", "name": "UITests" } },
                { "target": { "name": "UITests" } }
              ]
            }
            """

        let bundles = HookLogic.parseBundles(fromXCTestPlanData: Data(json.utf8))
        #expect(bundles == ["UnitTests", "UITests"])
    }

    @Test
    func `parse bundles returns nil for invalid input`() {
        #expect(HookLogic.parseBundles(fromXCTestPlanData: Data("not-json".utf8)) == nil)
    }

    @Test
    func `resolve available bundles returns empty when plan is missing`() {
        let resolution = HookLogic.resolveAvailableBundles(
            repoRoot: "/tmp/nonexistent-\(UUID())",
            testPlanRelativePath: "missing.xctestplan",
        )
        #expect(!resolution.loadedFromXCTestPlan)
        #expect(resolution.bundles.isEmpty)
    }

    // MARK: - Bundle selection

    @Test
    func `select bundles maps directory to test bundle`() {
        let files = ["ModuleA/Sources/Foo.swift", "ModuleB/Sources/Bar.swift"]
        let available = ["ModuleATests", "ModuleBTests", "ModuleCTests"]

        let selected = HookLogic.selectBundles(changedFiles: files, availableBundles: available)
        #expect(selected == ["ModuleATests", "ModuleBTests"])
    }

    @Test
    func `select bundles returns empty when no matches`() {
        let files = ["README.md", "docs/adr.md"]
        let selected = HookLogic.selectBundles(changedFiles: files, availableBundles: ["FooTests"])
        #expect(selected.isEmpty)
    }

    @Test
    func `select bundles deduplicates`() {
        let files = ["ModuleA/Sources/A.swift", "ModuleA/Sources/B.swift"]
        let selected = HookLogic.selectBundles(changedFiles: files, availableBundles: ["ModuleATests"])
        #expect(selected == ["ModuleATests"])
    }

    @Test
    func `select bundles matches exact bundle name`() {
        let files = ["CoreTests/Tests/FooTest.swift"]
        let selected = HookLogic.selectBundles(changedFiles: files, availableBundles: ["CoreTests"])
        #expect(selected == ["CoreTests"])
    }
}
