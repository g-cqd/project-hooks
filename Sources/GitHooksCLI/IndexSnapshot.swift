import Foundation
import GitHooksCore

/// A private copy of files as the index holds them, for linters to read.
///
/// The working tree can differ from what the commit contains: `git add -p` stages some hunks and leaves others, and an
/// editor can save while the hook runs. The snapshot holds the staged version of the files to lint and of every lint
/// configuration file, at their repository-relative paths. It never touches the working tree.
struct IndexSnapshot {
    /// The snapshot's directory, which stands for the repository root.
    let root: String

    /// SwiftLint configurations can include one another through `parent_config` and `child_config`.
    private static let maxSwiftLintIncludeDepth = 8

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
        // SwiftLint applies `excluded:` only to canonical paths, so the snapshot lives under `/private/var`, not
        // `/var`.
        let root =
            canonicalPath(FileManager.default.temporaryDirectory.path) + "/project-hooks-index-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let snapshot = IndexSnapshot(root: root)
        do {
            let pathspecs = LintConfiguration.fileNames.sorted().map { ":(glob)**/\($0)" }
            let configurations = try gitNullSeparated(
                ["ls-files", "-z", "--cached", "--"] + pathspecs,
                repoRoot: repoRoot,
            )
            try snapshot.checkOut(paths + configurations, repoRoot: repoRoot)
            try snapshot.checkOutSwiftLintIncludes(of: configurations, repoRoot: repoRoot)
        } catch {
            snapshot.remove()
            throw error
        }
        return snapshot
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func checkOut(_ paths: [String], repoRoot: String) throws {
        let unique = Array(Set(paths))
        guard !unique.isEmpty else { return }
        let result = try runCommand(
            ["git", "checkout-index", "-z", "--stdin", "--prefix=\(root)/"],
            currentDirectory: repoRoot,
            input: Data(unique.joined(separator: "\0").utf8),
        )
        guard result.exitCode == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("Could not copy staged files for linting: \(stderr)")
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
            let staged = try gitNullSeparated(
                ["ls-files", "-z", "--cached", "--"] + included.map { ":(literal)\($0)" },
                repoRoot: repoRoot,
            )
            try checkOut(staged, repoRoot: repoRoot)
            pending = staged
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

/// Where linters read files, and which directory their output should name instead.
struct LintWorkspace {
    /// The directory that holds the files to lint and their configuration.
    let root: String
    /// The repository's working tree, which the hook's output names instead of `root`.
    let repoRoot: String

    /// A workspace that is the working tree itself.
    init(repoRoot: String) {
        root = repoRoot
        self.repoRoot = repoRoot
    }

    init(snapshot: IndexSnapshot, repoRoot: String) {
        root = snapshot.root
        self.repoRoot = repoRoot
    }

    /// `text` with every spelling of `root` replaced by `repoRoot`.
    func repositoryPaths(in text: String) -> String {
        guard root != repoRoot else { return text }
        // macOS temporary paths also appear through the `/private` symbolic link. Replace the longer spelling first.
        let spellings =
            root.hasPrefix("/private/")
            ? [root, String(root.dropFirst("/private".count))]
            : ["/private\(root)", root]
        return spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: repoRoot) }
    }
}

/// `path` with every symbolic link resolved, including the `/var` link to `/private/var`, which
/// `URL.resolvingSymlinksInPath()` deliberately keeps.
///
/// Returns `path` unchanged when it does not exist.
func canonicalPath(_ path: String) -> String {
    // `realpath` returns a buffer from `malloc`, or nil. The string copies it before the buffer is freed.
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
