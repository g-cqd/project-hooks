import Foundation

/// Finds git directories on disk by reading `.git` entries, without running git.
public enum GitDirectoryLocator {
    /// Directories that hold build output or dependencies, whose clones are not the user's repositories.
    static let skippedDirectoryNames: Set<String> = [
        ".build", ".git", ".gradle", ".swiftpm", "Carthage", "DerivedData", "Pods", "node_modules",
    ]

    /// The git directories of the repositories at or below `root`, and of their submodules.
    ///
    /// A linked worktree resolves to the git directory of its repository, which holds the hooks. The walk does not
    /// follow symbolic links, skips `skippedDirectoryNames`, and stops `maxDepth` levels below `root`.
    /// - Returns: Absolute paths with symbolic links resolved, sorted, without duplicates.
    /// - Complexity: O(n), where n is the number of directories visited.
    public static func gitDirectories(under root: String, maxDepth: Int) -> [String] {
        let fileManager = FileManager.default
        var found = Set<String>()
        var pending = [(path: URL(fileURLWithPath: root).resolvingSymlinksInPath(), depth: 0)]

        while let (directory, depth) = pending.popLast() {
            if let gitDirectory = gitDirectory(forDotGit: directory.appendingPathComponent(".git")) {
                found.insert(gitDirectory.path)
                found.formUnion(submoduleGitDirectories(in: gitDirectory).map(\.path))
            }
            guard depth < maxDepth else { continue }

            let children =
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                )) ?? []
            for child in children where !skippedDirectoryNames.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true {
                    pending.append((child, depth + 1))
                }
            }
        }

        return found.sorted()
    }

    /// The git directory that a `.git` entry designates: the entry itself when it is a directory, or, when it is a
    /// `gitdir:` file, the common directory of the worktree or submodule it points to.
    static func gitDirectory(forDotGit dotGit: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit.resolvingSymlinksInPath() }

        guard let pointer = firstLine(of: dotGit), pointer.hasPrefix("gitdir:") else { return nil }
        let target = resolve(
            String(pointer.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces),
            against: dotGit.deletingLastPathComponent(),
        )
        // A linked worktree's directory names the repository's common directory in `commondir`.
        guard let common = firstLine(of: target.appendingPathComponent("commondir")) else {
            return target.resolvingSymlinksInPath()
        }
        return resolve(common, against: target).resolvingSymlinksInPath()
    }

    /// Submodule git directories below `gitDirectory/modules`, at any nesting level.
    ///
    /// A submodule's name can contain slashes, so a directory counts only when it holds `HEAD` and `config`.
    static func submoduleGitDirectories(in gitDirectory: URL) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        var pending = [gitDirectory.appendingPathComponent("modules")]

        while let directory = pending.popLast() {
            let children =
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                )) ?? []
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let isGitDirectory =
                    fileManager.fileExists(atPath: child.appendingPathComponent("HEAD").path)
                    && fileManager.fileExists(atPath: child.appendingPathComponent("config").path)
                if isGitDirectory {
                    found.append(child.resolvingSymlinksInPath())
                    pending.append(child.appendingPathComponent("modules"))
                } else {
                    pending.append(child)
                }
            }
        }

        return found
    }

    private static func firstLine(of file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = contents.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    private static func resolve(_ path: String, against base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardized
    }
}
