import Foundation
import Testing

@testable import GitHooksCLI

/// The verification worktree keeps the repository's directory name.
///
/// A nested package that depends on its parent by path (`.package(path: "..")`) gets the parent's identity from
/// the parent's directory name, so without it such a package resolves in the repository and fails in the hook.
struct WorktreeNameTests {
    @Test
    func `the verification worktree keeps the repository's directory name`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let arguments = repository.scratch.appendingPathComponent("swift-arguments")
        try repository.installTool("swift", script: "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(arguments.path)'\n")
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        let head = try repository.commitAll("Add the package")
        try repository.trust()

        let run = try repository.runPrePush(localSHA: head)

        #expect(run.exitCode == 0, "\(run.output)")
        let recorded = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        let packagePath = try #require(recorded.firstIndex(of: "--package-path").map { recorded[$0 + 1] })
        #expect(URL(fileURLWithPath: packagePath).lastPathComponent == repository.root.lastPathComponent)
    }

    @Test
    func `a worktree that an earlier version left at the old path is removed`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installTool("swift", script: "#!/bin/sh\nexit 0\n")
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        let head = try repository.commitAll("Add the package")
        try repository.trust()
        let key = try HookCache.repositoryKey(repoRoot: repository.path)
        let legacy = repository.cacheDirectory.appendingPathComponent("worktrees/\(key)")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try repository.git("worktree", "add", "--detach", "--quiet", legacy.path, head)

        let run = try repository.runPrePush(localSHA: head)

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(try repository.worktreePaths() == [repository.path])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
