/// How one linter run ended.
public enum LintOutcome: Equatable, Sendable {
    /// The linter checked the files and found nothing to report.
    case passed
    /// The linter's configuration excludes every file it was given, so it checked nothing.
    case allFilesExcluded
    /// The linter found violations.
    case violations
    /// The linter did not check the files, for example because of a usage or configuration error.
    case failed(exitCode: Int32)
    /// The linter ran past its timeout and was stopped.
    case timedOut

    /// Whether the commit or push may proceed.
    public var passes: Bool {
        self == .passed || self == .allFilesExcluded
    }

    /// Classify a finished linter run.
    ///
    /// Each linter reports violations with its own exit code. Any other non-zero exit means that the linter failed to
    /// run, which still blocks, but is not a finding in the code.
    /// - Parameters:
    ///   - linterName: The `DiscoveredLinter.name` of the linter.
    ///   - exitCode: The linter's exit status.
    ///   - output: The linter's standard output and standard error.
    /// - Returns: How the run ended.
    public static func classify(linterName: String, exitCode: Int32, output: String) -> LintOutcome {
        if exitCode == 0 { return .passed }

        switch (linterName, exitCode) {
            case ("swift-format", 1) where output.contains("Unable to read configuration"):
                // swift-format uses exit 1 for violations and for a configuration that its version cannot read.
                return .failed(exitCode: 1)
            case ("SwiftLint", 2), ("detekt", 2), ("swift-format", 1), ("SwiftFormat", 1), ("ktlint", 1):
                return .violations
            case ("SwiftLint", 1) where output.contains("No lintable files found"):
                // With `--force-exclude`, SwiftLint reports a group whose files are all excluded this way.
                return .allFilesExcluded
            default:
                return .failed(exitCode: exitCode)
        }
    }
}
