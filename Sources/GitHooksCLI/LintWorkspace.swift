/// Where linters read files, and which directory their output should name instead.
struct LintWorkspace {
    /// The directory that holds the files to lint and their configuration.
    let root: String
    /// The repository's working tree, which the hook's output names instead of `root`.
    let repoRoot: String
    /// The blob hash of each file in the workspace, by repository-relative path, when git provided the files.
    let blobs: [String: String]
    /// A digest of the workspace's lint configuration files, when git provided them.
    let configurationDigest: String?

    /// A workspace that is the working tree itself.
    init(repoRoot: String) {
        root = repoRoot
        self.repoRoot = repoRoot
        blobs = [:]
        configurationDigest = nil
    }

    init(snapshot: IndexSnapshot, repoRoot: String) {
        root = snapshot.root
        self.repoRoot = repoRoot
        blobs = snapshot.blobs
        configurationDigest = snapshot.configurationDigest
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
