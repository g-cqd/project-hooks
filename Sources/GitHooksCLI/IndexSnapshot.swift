import Foundation
import GitHooksCore

/// A private copy of files as an index holds them, for linters to read.
///
/// The working tree can differ from what a commit contains: `git add -p` stages some hunks and leaves others, an
/// editor can save while the hook runs, and a push can send a branch that is not checked out. The snapshot holds the
/// files to lint, and every lint configuration file, as the repository's index or a commit holds them, at their
/// repository-relative paths. It never touches the working tree or the repository's index.
struct IndexSnapshot {
    /// The snapshot's directory, which stands for the repository root.
    let root: String
    /// The requested paths that the index holds, and that the snapshot therefore contains.
    private(set) var files: [String] = []
    /// The environment for git commands that read the snapshot's index.
    ///
    /// Nil for the repository's own index.
    private var indexEnvironment: [String: String]?

    /// SwiftLint configurations can include one another through `parent_config` and `child_config`.
    private static let maxSwiftLintIncludeDepth = 8

    init(root: String) {
        self.root = root
    }

    /// Copy `paths`, and every lint configuration file, from the index into a new temporary directory.
    ///
    /// Git reads the index that `GIT_INDEX_FILE` names, so `git commit -a` and `git commit <paths>` snapshot the index
    /// that they are about to commit.
    /// - Parameters:
    ///   - repoRoot: The repository's working tree, where git runs.
    ///   - paths: Repository-relative paths of staged files.
    /// - Returns: The snapshot, which the caller removes with `remove()`.
    /// - Throws: When git cannot list or copy the files.
    static func take(repoRoot: String, paths: [String]) throws -> IndexSnapshot {
        try take(repoRoot: repoRoot, paths: paths, commit: nil)
    }

    /// Copy `paths`, and every lint configuration file, as `commit` holds them, into a new temporary directory.
    ///
    /// A temporary index stands for the commit, so neither the repository's index nor its working tree changes.
    /// - Parameters:
    ///   - repoRoot: The repository's working tree, where git runs.
    ///   - paths: Repository-relative paths of files in `commit`, or in the index when `commit` is nil.
    ///   - commit: The commit to copy the files from, or nil for the index.
    /// - Returns: The snapshot, which the caller removes with `remove()`.
    /// - Throws: When git cannot read the commit, or list or copy the files.
    static func take(repoRoot: String, paths: [String], commit: String?) throws -> IndexSnapshot {
        // SwiftLint applies `excluded:` only to canonical paths: the snapshot lives under `/private/var`, not `/var`.
        let temporary = canonicalPath(FileManager.default.temporaryDirectory.path)
        var snapshot = IndexSnapshot(root: "\(temporary)/project-hooks-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: snapshot.root, withIntermediateDirectories: true)
        do {
            if let commit {
                snapshot.indexEnvironment = ["GIT_INDEX_FILE": "\(snapshot.root).index"]
                _ = try snapshot.git(["read-tree", commit], repoRoot: repoRoot)
            }
            // A path that a pushed range changed can be absent from its last commit.
            snapshot.files =
                try paths.isEmpty
                ? []
                : snapshot.git(
                    ["ls-files", "-z", "--cached", "--"] + paths.map { ":(literal)\($0)" },
                    repoRoot: repoRoot,
                )
            let pathspecs = LintConfiguration.fileNames.sorted().map { ":(glob)**/\($0)" }
            let configurations = try snapshot.git(["ls-files", "-z", "--cached", "--"] + pathspecs, repoRoot: repoRoot)
            try snapshot.checkOut(snapshot.files + configurations, repoRoot: repoRoot)
            try snapshot.checkOutSwiftLintIncludes(of: configurations, repoRoot: repoRoot)
        } catch {
            snapshot.remove()
            throw error
        }
        return snapshot
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: "\(root).index")
    }

    private func git(_ arguments: [String], repoRoot: String) throws -> [String] {
        try gitNullSeparated(arguments, repoRoot: repoRoot, environment: indexEnvironment)
    }

    private func checkOut(_ paths: [String], repoRoot: String) throws {
        let unique = Array(Set(paths))
        guard !unique.isEmpty else { return }
        let result = try runCommand(
            ["git", "checkout-index", "-z", "--stdin", "--prefix=\(root)/"],
            currentDirectory: repoRoot,
            environment: indexEnvironment,
            input: Data(unique.joined(separator: "\0").utf8),
        )
        guard result.exitCode == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("Could not copy files for linting: \(stderr)")
        }
    }

    /// Copy the files that the copied SwiftLint configurations include, so that SwiftLint does not fall back to its
    /// default rules when an included configuration is missing.
    private func checkOutSwiftLintIncludes(of configurations: [String], repoRoot: String) throws {
        let swiftLintNames: Set = [".swiftlint.yml", ".swiftlint.yaml"]
        var pending = configurations.filter { swiftLintNames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        var seen = Set(configurations)

        for _ in 0..<Self.maxSwiftLintIncludeDepth where !pending.isEmpty {
            var included: [String] = []
            for configuration in pending {
                let url = URL(fileURLWithPath: root).appendingPathComponent(configuration)
                guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let directory = (configuration as NSString).deletingLastPathComponent
                for reference in LintConfiguration.swiftLintReferences(in: yaml) {
                    guard let path = Self.repositoryPath(of: reference, from: directory),
                        seen.insert(path).inserted
                    else { continue }
                    included.append(path)
                }
            }
            guard !included.isEmpty else { return }
            // Only files that the index holds can be copied from it.
            let indexed = try git(
                ["ls-files", "-z", "--cached", "--"] + included.map { ":(literal)\($0)" },
                repoRoot: repoRoot,
            )
            try checkOut(indexed, repoRoot: repoRoot)
            pending = indexed
        }
    }

    /// The repository-relative path that `reference`, relative to `directory`, designates, or nil when the reference is
    /// absolute or leaves the repository.
    static func repositoryPath(of reference: String, from directory: String) -> String? {
        guard !reference.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in "\(directory)/\(reference)".split(separator: "/") {
            switch component {
                case ".":
                    continue
                case "..":
                    guard components.popLast() != nil else { return nil }
                default:
                    components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}
