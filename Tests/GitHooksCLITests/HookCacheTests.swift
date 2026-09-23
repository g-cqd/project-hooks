import Foundation
import Testing

@testable import GitHooksCLI

struct HookCacheTests {
    @Test(arguments: [nil, "", "cache", "./cache", "../cache"] as [String?])
    func `the cache stays out of the repository unless an absolute path is configured`(configured: String?) {
        #expect(
            HookCache.root(configured: configured, caches: "/Users/me/Library/Caches")
                == "/Users/me/Library/Caches/project-hooks")
    }

    @Test
    func `an absolute or home-relative cache directory is used`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(HookCache.root(configured: "/opt/cache", caches: "/c") == "/opt/cache")
        #expect(HookCache.root(configured: "~/hook-cache", caches: "/c").hasSuffix("/hook-cache"))
        #expect(HookCache.root(configured: "~/hook-cache", caches: "/c").hasPrefix(canonicalPath(home)))
    }

    @Test
    func `a repository's key names it, and differs between clones`() {
        #expect(HookCache.sanitized("My App (copy)") == "My_App__copy_")
        #expect(HookCache.sanitized("") == "repository")
        #expect(HookCache.digest(["a", "bc"]) != HookCache.digest(["ab", "c"]))
    }
}
