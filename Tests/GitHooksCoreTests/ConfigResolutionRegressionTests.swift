import Foundation
@testable import GitHooksCore
import Testing

struct ConfigResolutionRegressionTests {
    // MARK: - Fallback chain with real files

    @Test
    func `xdg config is used when local config absent`() throws {
        let dir = try makeTempDir(prefix: "xdg-fallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoRoot = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let xdgDir = dir.appendingPathComponent("xdg-config")
        try FileManager.default.createDirectory(at: xdgDir, withIntermediateDirectories: true)

        let yaml = """
        pre-commit:
          tasks:
            - name: xdg-task
              run: echo xdg
        """
        try yaml.write(to: xdgDir.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(
            atPath: xdgDir.appendingPathComponent("config.yml").path,
            repoRoot: repoRoot.path,
        )
        #expect(config != nil)
        #expect(config?.preCommit.tasks.count == 1)
        #expect(config?.preCommit.tasks[0].name == "xdg-task")
    }

    @Test
    func `home config is used when local and xdg absent`() throws {
        let dir = try makeTempDir(prefix: "home-fallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoRoot = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let yaml = """
        pre-push:
          reject-trailers:
            - "Signed-off-by"
        """
        let homePath = dir.appendingPathComponent(".project-hooks.yml")
        try yaml.write(to: homePath, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: homePath.path, repoRoot: repoRoot.path)
        #expect(config != nil)
        #expect(config?.prePush.rejectTrailers == ["Signed-off-by"])
    }

    @Test
    func `loadUserConfig returns nil for nonexistent file`() throws {
        let config = try HooksConfig.loadUserConfig(
            atPath: "/tmp/nonexistent-\(UUID().uuidString)/config.yml",
            repoRoot: "/tmp/some-repo",
        )
        #expect(config == nil)
    }

    // MARK: - Projects-list edge cases

    @Test
    func `projects list with empty projects dict returns nil`() throws {
        let dir = try makeTempDir(prefix: "empty-projects")
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        projects: {}
        """
        let path = dir.appendingPathComponent("config.yml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/Users/dev/repo")
        #expect(config == nil)
    }

    @Test
    func `projects list where no pattern matches returns nil`() throws {
        let dir = try makeTempDir(prefix: "no-match")
        defer { try? FileManager.default.removeItem(at: dir) }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let yaml = """
        projects:
          ~/Developer/work/*:
            pre-commit:
              tasks:
                - name: work-lint
                  run: swiftlint
        """
        let path = dir.appendingPathComponent("config.yml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let unrelatedRepo = (homeDir as NSString).appendingPathComponent("Documents/unrelated-repo")
        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: unrelatedRepo)
        #expect(config == nil)
    }

    @Test
    func `projects list with matched entry having null value returns empty config`() throws {
        let result = try HooksConfig.parseProjectsList(
            ["/tmp/repo": NSNull()],
            repoRoot: "/tmp/repo",
        )
        #expect(result == HooksConfig())
    }

    @Test
    func `projects list with matched entry having string value returns empty config`() throws {
        let result = try HooksConfig.parseProjectsList(
            ["/tmp/repo": "invalid"],
            repoRoot: "/tmp/repo",
        )
        #expect(result == HooksConfig())
    }

    @Test
    func `projects list with matched entry having array value returns empty config`() throws {
        let result = try HooksConfig.parseProjectsList(
            ["/tmp/repo": ["not", "a", "dict"]],
            repoRoot: "/tmp/repo",
        )
        #expect(result == HooksConfig())
    }

    @Test
    func `projects list matched entry with malformed tasks skips them gracefully`() throws {
        let projectConfig: [String: Any] = [
            "pre-commit": [
                "tasks": [
                    ["name": "valid-task", "run": "echo ok"],
                    ["broken": true],
                ],
            ],
        ]

        let result = try HooksConfig.parseProjectsList(
            ["/tmp/repo": projectConfig],
            repoRoot: "/tmp/repo",
        )

        #expect(result != nil)
        #expect(result?.preCommit.tasks.count == 1)
        #expect(result?.preCommit.tasks[0].name == "valid-task")
    }

    @Test
    func `projects list with multiple patterns first alphabetical match wins`() throws {
        let projects: [String: Any] = [
            "/z-path/*": ["pre-commit": ["tasks": [["name": "z-task", "run": "echo z"]]]],
            "/a-path/*": ["pre-commit": ["tasks": [["name": "a-task", "run": "echo a"]]]],
            "/m-path/*": ["pre-commit": ["tasks": [["name": "m-task", "run": "echo m"]]]],
        ]

        let result = try HooksConfig.parseProjectsList(projects, repoRoot: "/a-path/repo")
        #expect(result?.preCommit.tasks[0].name == "a-task")
    }

    @Test
    func `projects list specific pattern wins over broad if sorted first`() throws {
        let projects: [String: Any] = [
            "/Users/dev/*": ["pre-commit": ["tasks": [["name": "broad", "run": "echo broad"]]]],
            "/Users/dev/work/*": ["pre-commit": ["tasks": [["name": "specific", "run": "echo specific"]]]],
        ]

        // "/Users/dev/*" sorts before "/Users/dev/work/*" and both match
        let result = try HooksConfig.parseProjectsList(projects, repoRoot: "/Users/dev/work/app")
        #expect(result?.preCommit.tasks[0].name == "broad")
    }

    // MARK: - Format detection edge cases

    @Test
    func `file with both projects key and hook keys uses projects semantics`() throws {
        let dir = try makeTempDir(prefix: "mixed-keys")
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        projects:
          /tmp/repo:
            pre-commit:
              tasks:
                - name: projects-task
                  run: echo from-projects
        pre-commit:
          tasks:
            - name: flat-task
              run: echo from-flat
        """
        let path = dir.appendingPathComponent("config.yml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/tmp/repo")
        #expect(config?.preCommit.tasks[0].name == "projects-task")
    }

    @Test
    func `file with projects key but value is not a dict falls through to flat`() throws {
        let dir = try makeTempDir(prefix: "projects-not-dict")
        defer { try? FileManager.default.removeItem(at: dir) }

        // "projects" is a string, not a dict — so `as? [String: Any]` fails
        // and it falls through to flat parsing
        let yaml = """
        projects: "not a dict"
        pre-commit:
          tasks:
            - name: flat-task
              run: echo flat
        """
        let path = dir.appendingPathComponent("config.yml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/anything")
        #expect(config?.preCommit.tasks[0].name == "flat-task")
    }

    @Test
    func `empty YAML file returns empty config`() throws {
        let dir = try makeTempDir(prefix: "empty-yaml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("config.yml")
        try "".write(to: path, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/tmp/repo")
        #expect(config == HooksConfig())
    }

    @Test
    func `whitespace only YAML file returns empty config`() throws {
        let dir = try makeTempDir(prefix: "whitespace-yaml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("config.yml")
        try "   \n\n  \n".write(to: path, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/tmp/repo")
        #expect(config == HooksConfig())
    }

    @Test
    func `YAML comment only file returns empty config`() throws {
        let dir = try makeTempDir(prefix: "comment-yaml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("config.yml")
        try "# just a comment\n# another comment\n".write(to: path, atomically: true, encoding: .utf8)

        let config = try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/tmp/repo")
        #expect(config == HooksConfig())
    }

    // MARK: - Tilde expansion edge cases

    @Test
    func `tilde expansion with empty homeDir`() {
        let expanded = HooksConfig.expandTilde("~/projects", homeDir: "")
        #expect(expanded == "projects")
    }

    @Test
    func `tilde expansion with trailing slash homeDir`() {
        let expanded = HooksConfig.expandTilde("~/work", homeDir: "/Users/dev/")
        // NSString.appendingPathComponent handles trailing slash
        #expect(expanded == "/Users/dev/work")
    }

    @Test
    func `tilde expansion preserves glob characters`() {
        let expanded = HooksConfig.expandTilde("~/dev/*/src", homeDir: "/home/user")
        #expect(expanded == "/home/user/dev/*/src")
    }

    @Test
    func `tilde expansion with tilde user syntax is not expanded`() {
        // ~otheruser/path should NOT be expanded (we only handle bare ~)
        let expanded = HooksConfig.expandTilde("~otheruser/path", homeDir: "/home/me")
        #expect(expanded == "~otheruser/path")
    }

    // MARK: - fnmatch pattern edge cases

    @Test
    func `fnmatch bracket expression`() {
        #expect(HooksConfig.matchesPattern("/dev/project-[abc]", path: "/dev/project-a"))
        #expect(HooksConfig.matchesPattern("/dev/project-[abc]", path: "/dev/project-b"))
        #expect(!HooksConfig.matchesPattern("/dev/project-[abc]", path: "/dev/project-d"))
    }

    @Test
    func `fnmatch negated bracket expression`() {
        #expect(HooksConfig.matchesPattern("/dev/project-[!abc]", path: "/dev/project-d"))
        #expect(!HooksConfig.matchesPattern("/dev/project-[!abc]", path: "/dev/project-a"))
    }

    @Test
    func `fnmatch star does not match empty string at end`() {
        // "/dev/work/" requires trailing slash; "/dev/work" does not have one
        #expect(!HooksConfig.matchesPattern("/dev/work/?*", path: "/dev/work/"))
    }

    @Test
    func `fnmatch matches deeply nested path without FNM_PATHNAME`() {
        #expect(HooksConfig.matchesPattern("/dev/*", path: "/dev/a/b/c/d/e"))
    }

    @Test
    func `fnmatch empty pattern matches empty path`() {
        #expect(HooksConfig.matchesPattern("", path: ""))
    }

    @Test
    func `fnmatch empty pattern does not match non-empty path`() {
        #expect(!HooksConfig.matchesPattern("", path: "/some/path"))
    }

    @Test
    func `fnmatch non-empty pattern does not match empty path`() {
        #expect(!HooksConfig.matchesPattern("/dev/*", path: ""))
    }

    @Test
    func `fnmatch escaped special characters`() {
        #expect(HooksConfig.matchesPattern("/dev/project\\-1", path: "/dev/project-1"))
    }

    @Test
    func `fnmatch with unicode path`() {
        #expect(HooksConfig.matchesPattern("/Users/développeur/*", path: "/Users/développeur/projet"))
    }

    // MARK: - Path normalization concerns

    @Test
    func `pattern without trailing slash matches repo without trailing slash`() {
        #expect(HooksConfig.matchesPattern("/Users/dev/repo", path: "/Users/dev/repo"))
    }

    @Test
    func `pattern with trailing star does not match parent`() {
        #expect(!HooksConfig.matchesPattern("/Users/dev/work/*", path: "/Users/dev/work"))
    }

    @Test
    func `pattern matches repo root with trailing slash stripped`() {
        // fnmatch is literal — trailing slash in pattern requires trailing slash in path
        #expect(!HooksConfig.matchesPattern("/Users/dev/work/", path: "/Users/dev/work"))
        #expect(HooksConfig.matchesPattern("/Users/dev/work/", path: "/Users/dev/work/"))
    }

    // MARK: - Backward compatibility

    @Test
    func `load returns same config as resolve`() throws {
        let dir = try makeTempDir(prefix: "compat")
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        pre-commit:
          tasks:
            - name: compat-check
              run: echo compat
        pre-push:
          reject-trailers:
            - "WIP"
          tasks:
            - name: changelog
              run: scripts/changelog.sh
        """
        try yaml.write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        let loaded = try HooksConfig.load(repoRoot: dir.path)
        let resolved = try HooksConfig.resolve(repoRoot: dir.path)

        #expect(loaded == resolved?.config)
        #expect(resolved?.source == .local)
    }

    @Test
    func `load returns nil same as resolve when no config`() throws {
        let dir = try makeTempDir(prefix: "compat-nil")
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = try HooksConfig.load(repoRoot: dir.path)
        let resolved = try HooksConfig.resolve(repoRoot: dir.path)

        // Both should be nil if no user-level config matches this temp path
        if resolved == nil {
            #expect(loaded == nil)
        } else {
            #expect(loaded == resolved?.config)
        }
    }

    // MARK: - Full config parsing through projects-list

    @Test
    func `projects list entry with full config is parsed correctly`() throws {
        let projectConfig: [String: Any] = [
            "pre-commit": [
                "tasks": [
                    ["name": "format", "run": "swift-format .", "on-files": ["*.swift"], "timeout": 90],
                ],
            ],
            "pre-push": [
                "commit-message": ["pattern": "^TICKET-\\d+", "error": "Need ticket"],
                "reject-trailers": ["Co-authored-by"],
                "test-override": ["type": "swift"],
                "tasks": [
                    ["name": "docs", "run": "scripts/docs.sh"],
                ],
            ],
        ]

        let result = try HooksConfig.parseProjectsList(
            ["/repos/*": projectConfig],
            repoRoot: "/repos/my-app",
        )

        #expect(result != nil)
        #expect(result?.preCommit.tasks.count == 1)
        #expect(result?.preCommit.tasks[0].name == "format")
        #expect(result?.preCommit.tasks[0].onFiles == ["*.swift"])
        #expect(result?.preCommit.tasks[0].timeout == 90)

        #expect(result?.prePush.commitMessage?.pattern == "^TICKET-\\d+")
        #expect(result?.prePush.commitMessage?.error == "Need ticket")
        #expect(result?.prePush.rejectTrailers == ["Co-authored-by"])
        #expect(result?.prePush.testOverride?.type == .swift)
        #expect(result?.prePush.tasks.count == 1)
        #expect(result?.prePush.tasks[0].name == "docs")
    }

    @Test
    func `projects list entry with restage configurations`() throws {
        let projectConfig: [String: Any] = [
            "pre-commit": [
                "tasks": [
                    ["name": "gen", "run": "swiftgen", "restage": true],
                    ["name": "assets", "run": "gen-assets", "restage": ["Generated/Assets.swift"]],
                ],
            ],
        ]

        let result = try HooksConfig.parseProjectsList(
            ["/repos/*": projectConfig],
            repoRoot: "/repos/app",
        )

        #expect(result?.preCommit.tasks[0].restage == .matchedFiles)
        #expect(result?.preCommit.tasks[1].restage == .paths(["Generated/Assets.swift"]))
    }

    @Test
    func `projects list entry with task dependency chain`() throws {
        let projectConfig: [String: Any] = [
            "pre-commit": [
                "tasks": [
                    ["name": "lint", "run": "swiftlint"],
                    ["name": "format", "run": "swift-format", "after": "lint"],
                ],
            ],
        ]

        let result = try HooksConfig.parseProjectsList(
            ["/dev/*": projectConfig],
            repoRoot: "/dev/repo",
        )

        #expect(result?.preCommit.tasks[1].after == "lint")
    }

    // MARK: - Resolve integration with local overriding user-level

    @Test
    func `local config completely replaces user-level config`() throws {
        let dir = try makeTempDir(prefix: "replace-semantic")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create local config with only pre-commit
        let localYaml = """
        pre-commit:
          tasks:
            - name: local-only
              run: echo local
        """
        try localYaml.write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        let resolved = try HooksConfig.resolve(repoRoot: dir.path)

        #expect(resolved?.source == .local)
        #expect(resolved?.config.preCommit.tasks.count == 1)
        #expect(resolved?.config.preCommit.tasks[0].name == "local-only")
        // pre-push is empty — no merging from any user-level config
        #expect(resolved?.config.prePush.tasks.isEmpty == true)
        #expect(resolved?.config.prePush.commitMessage == nil)
    }

    // MARK: - ResolvedConfig struct

    @Test
    func `ResolvedConfig equatable compares both fields`() {
        let config1 = ResolvedConfig(config: HooksConfig(), source: .local)
        let config2 = ResolvedConfig(config: HooksConfig(), source: .local)
        let config3 = ResolvedConfig(config: HooksConfig(), source: .home)

        #expect(config1 == config2)
        #expect(config1 != config3)
    }

    @Test
    func `ResolvedConfig equatable compares config content`() {
        let configA = HooksConfig(preCommit: .init(tasks: [
            .init(name: "a", run: "echo a"),
        ]))
        let configB = HooksConfig()

        let resolved1 = ResolvedConfig(config: configA, source: .local)
        let resolved2 = ResolvedConfig(config: configB, source: .local)

        #expect(resolved1 != resolved2)
    }

    // MARK: - ConfigSource completeness

    @Test
    func `all ConfigSource cases have distinct descriptions`() {
        let descriptions = Set([
            ResolvedConfig(config: HooksConfig(), source: .local).sourceDescription,
            ResolvedConfig(config: HooksConfig(), source: .xdgConfig).sourceDescription,
            ResolvedConfig(config: HooksConfig(), source: .home).sourceDescription,
        ])
        #expect(descriptions.count == 3)
    }

    // MARK: - Error propagation

    @Test
    func `malformed YAML in user config throws`() throws {
        let dir = try makeTempDir(prefix: "malformed")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("config.yml")
        try "{{{{ not valid yaml".write(to: path, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try HooksConfig.loadUserConfig(atPath: path.path, repoRoot: "/tmp/repo")
        }
    }

    @Test
    func `non-dict YAML in local config degrades to empty config via resolve`() throws {
        let dir = try makeTempDir(prefix: "nondict-local")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Yams parses this as a plain string, not a dict — graceful degradation
        try "just a string".write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        let resolved = try HooksConfig.resolve(repoRoot: dir.path)
        #expect(resolved?.source == .local)
        #expect(resolved?.config == HooksConfig())
    }

    @Test
    func `non-dict YAML in local config degrades to empty config via load`() throws {
        let dir = try makeTempDir(prefix: "nondict-load")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "just a string".write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        let config = try HooksConfig.load(repoRoot: dir.path)
        #expect(config == HooksConfig())
    }

    @Test
    func `truly malformed YAML throws via resolve`() throws {
        let dir = try makeTempDir(prefix: "malformed-resolve")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Duplicate keys with conflicting types triggers a Yams error
        let badYaml = """
        pre-commit:
          tasks:
        \t- broken indent with tab
        """
        try badYaml.write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        #expect(throws: (any Error).self) {
            try HooksConfig.resolve(repoRoot: dir.path)
        }
    }

    @Test
    func `truly malformed YAML throws via load`() throws {
        let dir = try makeTempDir(prefix: "malformed-load")
        defer { try? FileManager.default.removeItem(at: dir) }

        let badYaml = """
        pre-commit:
          tasks:
        \t- broken indent with tab
        """
        try badYaml.write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        #expect(throws: (any Error).self) {
            try HooksConfig.load(repoRoot: dir.path)
        }
    }
}
