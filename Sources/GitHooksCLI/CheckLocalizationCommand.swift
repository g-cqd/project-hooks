import ArgumentParser
import Foundation
import GitHooksCore

struct CheckLocalizationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-localization",
        abstract: "Find SwiftUI string literals that are missing a comment: argument",
        discussion: """
        Walks every .swift file under the supplied paths (or individual
        .swift files when paths are passed directly) and flags Text(...),
        Button(...), Label(...), Toggle(...), Picker(...), Section(...),
        TextField(...), .navigationTitle(...), Stepper(...), and
        DatePicker(...) call sites whose first string literal is not
        accompanied by a comment: parameter.

        Skip rules:
          - Lines containing `String(localized:`, `LocalizedStringKey(`,
            `LocalizedStringResource(`, `verbatim:`, debug-only APIs
            (Logger, print, fatalError, etc.).
          - Lines marked with the escape-hatch comment
            (`// not-localized` by default).
          - Files inside #Preview { … } blocks or whose name ends in
            `Preview.swift` / `Previews.swift`.

        Exit code is 1 when at least one issue is found, 0 otherwise.
        """,
    )

    @Argument(help: "Directories or .swift files to scan (defaults to the current directory)")
    var paths: [String] = []

    @Option(help: "Substring that marks a line as intentionally not-localized")
    var allowComment: String = "not-localized"

    @Option(help: "Output format: text (xcode-style) or json")
    var format: Format = .text

    @Flag(help: "Include preview files / #Preview blocks (off by default)")
    var includePreviews = false

    @Option(
        name: .customLong("files-from"),
        help: "Read paths from a file, one per line. Pass `-` to read from stdin.",
    )
    var filesFrom: String?

    enum Format: String, ExpressibleByArgument {
        case text, json
    }

    func run() throws {
        var combined = paths
        if let filesFrom {
            try combined.append(contentsOf: Self.readPaths(from: filesFrom))
        }
        // Empty input → "scan current directory" preserves the prior
        // behaviour for ad-hoc CLI usage.
        let resolved = combined.isEmpty ? ["."] : combined
        let scanRoots: [URL] = resolved.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let excludedSuffixes: [String] = includePreviews
            ? []
            : ["Preview.swift", "Previews.swift", "+Preview.swift"]
        let config = LocalizationAnalyzer.Configuration(
            allowComment: allowComment,
            excludedFilenameSuffixes: excludedSuffixes,
        )
        let analyzer = LocalizationAnalyzer(roots: scanRoots, configuration: config)
        let issues = try analyzer.analyze()

        switch format {
        case .text:
            for issue in issues {
                FileHandle.standardError.write(Data((issue.formatted + "\n").utf8))
            }
            if !issues.isEmpty {
                FileHandle.standardError.write(
                    Data("\nFound \(issues.count) localization issue(s).\n".utf8),
                )
            }
        case .json:
            let payload = issues.map { issue in
                [
                    "file": issue.file.path,
                    "line": issue.line,
                    "column": issue.column,
                    "snippet": issue.snippet,
                    "api": issue.api,
                    "kind": issue.kind.rawValue,
                ] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        if !issues.isEmpty {
            throw ExitCode.failure
        }
    }

    /// Reads a newline-delimited list of file paths from `source`. When
    /// `source == "-"`, reads from stdin (used by pre-commit hooks
    /// that pipe `git diff --cached --name-only` in).
    private static func readPaths(from source: String) throws -> [String] {
        let raw: String
        if source == "-" {
            let data = FileHandle.standardInput.availableData
            raw = String(decoding: data, as: UTF8.self)
        } else {
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            raw = String(decoding: data, as: UTF8.self)
        }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
