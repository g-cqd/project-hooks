import Foundation

/// Resolves the closest configuration file for a given path by walking up the directory tree.
public enum ConfigResolver {
    /// Walk up from `filePath` (relative to `repoRoot`) looking for any of `candidates`.
    /// Returns the absolute path of the first matching config file found, or `nil`.
    ///
    /// Example: for file `ModuleA/Sources/Foo.swift` and candidates `[".swiftlint.yml"]`,
    /// checks `ModuleA/Sources/.swiftlint.yml`, then `ModuleA/.swiftlint.yml`, then
    /// `<repoRoot>/.swiftlint.yml`.
    public static func findClosestConfig(
        forFile relativePath: String,
        repoRoot: String,
        candidates: [String],
    ) -> String? {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: repoRoot).standardized

        // Start from the file's parent directory
        var current = rootURL.appendingPathComponent(relativePath).deletingLastPathComponent().standardized

        while current.path.hasPrefix(rootURL.path) {
            for candidate in candidates {
                let configPath = current.appendingPathComponent(candidate).path
                if fileManager.fileExists(atPath: configPath) {
                    return configPath
                }
            }

            let parent = current.deletingLastPathComponent().standardized
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    /// Group files by their closest config file. Files that share the same config are grouped together.
    /// Files with no matching config are grouped under the `nil` key.
    public static func groupFilesByConfig(
        files: [String],
        repoRoot: String,
        candidates: [String],
    ) -> [(config: String?, files: [String])] {
        var groups: [String: [String]] = [:]
        var noConfig: [String] = []

        for file in files {
            if let config = findClosestConfig(forFile: file, repoRoot: repoRoot, candidates: candidates) {
                groups[config, default: []].append(file)
            } else {
                noConfig.append(file)
            }
        }

        var result: [(config: String?, files: [String])] = groups
            .sorted { $0.key < $1.key }
            .map { (config: $0.key as String?, files: $0.value) }

        if !noConfig.isEmpty {
            result.append((config: nil, files: noConfig))
        }

        return result
    }
}
