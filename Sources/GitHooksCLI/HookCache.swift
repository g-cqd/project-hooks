import CryptoKit
import Foundation

/// Where project-hooks keeps data between runs: build directories, verification worktrees and locks.
///
/// The location is `GITHOOKS_CACHE_DIR` when set, otherwise `~/Library/Caches/project-hooks`. Everything in it can be
/// deleted; the next run recreates what it needs.
enum HookCache {
    static var root: String {
        if let configured = ProcessInfo.processInfo.environment["GITHOOKS_CACHE_DIR"], !configured.isEmpty {
            return canonicalPath((configured as NSString).expandingTildeInPath)
        }
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return canonicalPath(caches.path) + "/project-hooks"
    }

    /// A stable name for the repository at `repoRoot`: its directory name, and a hash of its common git directory, so
    /// that all worktrees of a repository share a name and two clones never do.
    static func repositoryKey(repoRoot: String) throws -> String {
        let commonDirectory =
            try gitFirstLine(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                repoRoot: repoRoot,
            ) ?? repoRoot
        let canonical = URL(fileURLWithPath: canonicalPath(commonDirectory))
        let name =
            canonical.lastPathComponent == ".git"
            ? canonical.deletingLastPathComponent().lastPathComponent
            : canonical.lastPathComponent
        return "\(sanitized(name))-\(digest([canonical.path]).prefix(16))"
    }

    /// A hexadecimal SHA-256 of `parts`, each terminated by a NUL byte so that no two lists collide.
    static func digest(_ parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `name` with every character outside letters, digits, `.`, `_` and `-` replaced, for use in a file name.
    static func sanitized(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "_" }.prefix(40))
        return cleaned.isEmpty ? "repository" : cleaned
    }
}
