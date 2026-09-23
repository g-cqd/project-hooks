import Foundation
import GitHooksCore
import Testing

struct GitDirectoryLocatorTests {
    @Test
    func `finds repositories and submodules, and resolves worktrees to their repository`() throws {
        let root = try makeTempDir(prefix: "locator").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeRepository(at: root.appendingPathComponent("group/app"))
        let library = try makeRepository(at: root.appendingPathComponent("library"))
        try runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "libs/shared"],
            in: app,
        )
        try runGit(["worktree", "add", "-q", root.appendingPathComponent("app-feature").path], in: app)

        let found = GitDirectoryLocator.gitDirectories(under: root.path, maxDepth: 4)

        #expect(
            found == [
                app.appendingPathComponent(".git").path,
                app.appendingPathComponent(".git/modules/libs/shared").path,
                library.appendingPathComponent(".git").path,
            ])
    }

    @Test
    func `does not descend into build output, symbolic links, or past the depth limit`() throws {
        let root = try makeTempDir(prefix: "locator-limits").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeRepository(at: root.appendingPathComponent("app/.build/checkouts/dependency"))
        let outside = try makeRepository(at: makeTempDir(prefix: "locator-outside"))
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let deep = try makeRepository(at: root.appendingPathComponent("a/b/c"))

        #expect(GitDirectoryLocator.gitDirectories(under: root.path, maxDepth: 2).isEmpty)
        #expect(
            GitDirectoryLocator.gitDirectories(under: root.path, maxDepth: 3) == [
                deep.appendingPathComponent(".git").path
            ])
    }

    @Test
    func `a directory without repositories yields nothing`() throws {
        let root = try makeTempDir(prefix: "locator-empty")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(GitDirectoryLocator.gitDirectories(under: root.path, maxDepth: 4).isEmpty)
    }

    private func makeRepository(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: url)
        try "content\n".write(to: url.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try runGit(["add", "README"], in: url)
        try runGit(["commit", "-q", "-m", "Initial"], in: url)
        return url.resolvingSymlinksInPath()
    }
}
