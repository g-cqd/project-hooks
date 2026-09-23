import Foundation
import GitHooksCore

/// Remembers which files each linter passed, with which content and configuration.
///
/// Pre-push then does not lint again what the commit hook already linted, and a commit retried after a lint failure
/// lints only the files that did not pass. A file's key covers the linter's binary, every lint configuration file in
/// the snapshot, the file's path and its blob, so changing any of them lints the file again. SwiftLint results are not
/// cached when a configuration includes an external file or URL, or the snapshot cannot cover every include.
/// `GITHOOKS_NO_CACHE=1` lints everything.
struct LintLedger {
    let store: ResultCache

    static func standard() -> LintLedger {
        LintLedger(
            store: ResultCache(
                directory: HookCache.root + "/lint",
                isEnabled: ProcessInfo.processInfo.environment["GITHOOKS_NO_CACHE"] != "1",
                capacity: 50000,
            ))
    }

    /// The key of the result that `linter` gives for `file`.
    /// - Parameters:
    ///   - file: The file's repository-relative path.
    ///   - linter: The linter.
    ///   - linterIdentity: `identity(of: linter)`.
    ///   - workspace: The workspace that holds the file, which knows its content.
    /// - Returns: The key, or nil when the workspace does not know the file's content.
    func key(for file: String, linter: DiscoveredLinter, linterIdentity: String, workspace: LintWorkspace) -> String? {
        guard linter.name != "SwiftLint" || workspace.swiftLintCacheable else { return nil }
        guard let configuration = workspace.configurationDigest, let blob = workspace.blobs[file] else { return nil }
        // Change the version when the linters' flags change, since their verdicts can change with them.
        return HookCache.digest(["project-hooks lint v1", linter.name, linterIdentity, configuration, file, blob])
    }

    /// The linter's binary, after symbolic links, with its size and modification date, which change when it is updated,
    /// and the version that it reports from `directory`: a version manager's shim keeps its path, size and date when
    /// the version that it selects changes.
    static func identity(of linter: DiscoveredLinter, in directory: String) -> String {
        let binary = URL(fileURLWithPath: linter.executablePath).resolvingSymlinksInPath()
        let values = try? binary.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(String.init) ?? "?"
        let modified = values?.contentModificationDate.map { String($0.timeIntervalSince1970) } ?? "?"
        let probe =
            linter.usesSwiftSubcommand
            ? [linter.executablePath, "format", "--version"]
            : [linter.executablePath, "--version"]
        let version =
            (try? runCommand(probe, currentDirectory: directory, timeoutSeconds: 30))
            .flatMap { $0.exitCode == 0 ? $0.combinedText.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? "?"
        return "\(binary.path)|\(size)|\(modified)|\(version)"
    }
}
