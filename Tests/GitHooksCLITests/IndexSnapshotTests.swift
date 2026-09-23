import Testing

@testable import GitHooksCLI

struct IndexSnapshotTests {
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
