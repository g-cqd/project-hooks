import Foundation
import Testing

@testable import GitHooksCLI

struct IndexSnapshotTests {
    /// From the review of the PH-3 fix: one `:(literal)` pathspec per file exceeded macOS's 1 MB argument limit on a
    /// large push.
    @Test
    func `a commit with more files than one command line can name is copied`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let paths = (0..<20000).map { String(format: "Sources/Generated/Feature/GeneratedFeatureFile%05d.swift", $0) }
        try FileManager.default.createDirectory(
            at: repository.root.appendingPathComponent("Sources/Generated/Feature"),
            withIntermediateDirectories: true,
        )
        for path in paths {
            FileManager.default.createFile(
                atPath: repository.root.appendingPathComponent(path).path,
                contents: Data("let value = 1\n".utf8),
            )
        }
        let head = try repository.commitAll("Generate files")

        let snapshot = try IndexSnapshot.take(repoRoot: repository.path, paths: paths + ["Deleted.swift"], commit: head)
        defer { snapshot.remove() }

        #expect(snapshot.files.count == paths.count)
        #expect(paths.allSatisfy { snapshot.blobs[$0] != nil })
        #expect(FileManager.default.fileExists(atPath: "\(snapshot.root)/\(paths[19999])"))
    }

    @Test(
        arguments: [
            ("../lint/base.yml", "Sources", "lint/base.yml"),
            ("base.yml", "Sources/App", "Sources/App/base.yml"),
            ("./base.yml", "", "base.yml"),
            ("../../outside.yml", "Sources", nil),
            ("/etc/base.yml", "Sources", nil),
        ] as [(String, String, String?)])
    func `resolves a SwiftLint include against its configuration's directory`(
        reference: String,
        directory: String,
        expected: String?,
    ) {
        #expect(IndexSnapshot.repositoryPath(of: reference, from: directory) == expected)
    }

    @Test
    func `canonical paths resolve the private var link`() {
        #expect(canonicalPath("/var") == "/private/var")
        #expect(canonicalPath("/nonexistent/project-hooks") == "/nonexistent/project-hooks")
    }

    @Test
    func `linter output names the repository, whichever spelling of the temporary directory it uses`() {
        let workspace = LintWorkspace(
            snapshot: IndexSnapshot(root: "/var/folders/x/T/project-hooks-index-1"),
            repoRoot: "/Users/me/app",
        )
        let output = """
            /private/var/folders/x/T/project-hooks-index-1/A.swift:1:1: error
            /var/folders/x/T/project-hooks-index-1/B.swift:2:1: warning
            """

        #expect(
            workspace.repositoryPaths(in: output) == """
                /Users/me/app/A.swift:1:1: error
                /Users/me/app/B.swift:2:1: warning
                """)
    }
}
