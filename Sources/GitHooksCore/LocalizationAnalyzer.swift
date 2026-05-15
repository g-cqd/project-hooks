import Foundation

/// Static analyser that flags SwiftUI string-literal call sites missing
/// a `comment:` argument. Designed for the pre-commit hook: scans
/// staged `.swift` files, returns a list of issues for the runner to
/// surface and block on.
///
/// Detection is line-scoped regex (no SwiftSyntax dependency to keep
/// the runner fast). The trade-off is some false-positive surface on
/// odd line wraps; the `// not-localized` escape hatch and
/// `LocalizedStringResource` / `LocalizedStringKey` / `verbatim:` skip
/// rules cover the common false-positive shapes.
public struct LocalizationAnalyzer: Sendable {

    // MARK: - Issue

    public struct Issue: Equatable, Sendable {

        public enum Kind: String, Sendable, Equatable {
            case missingComment
        }

        public let file: URL
        public let line: Int          // 1-indexed
        public let column: Int        // 1-indexed, byte offset
        public let snippet: String
        public let api: String        // e.g. "Text", "Button"
        public let kind: Kind

        public init(file: URL, line: Int, column: Int, snippet: String, api: String, kind: Kind) {
            self.file = file
            self.line = line
            self.column = column
            self.snippet = snippet
            self.api = api
            self.kind = kind
        }

        /// `path/file.swift:42:13: warning: ...` style emitter for Xcode-friendly
        /// terminal output.
        public var formatted: String {
            "\(file.path):\(line):\(column): warning: \(api) literal missing `comment:` — \(snippet)"
        }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {

        public let allowComment: String
        public let excludedFilenameSuffixes: [String]
        public let scanHiddenDirectories: Bool

        public init(
            allowComment: String = "not-localized",
            excludedFilenameSuffixes: [String] = ["Preview.swift", "Previews.swift", "+Preview.swift"],
            scanHiddenDirectories: Bool = false
        ) {
            self.allowComment = allowComment
            self.excludedFilenameSuffixes = excludedFilenameSuffixes
            self.scanHiddenDirectories = scanHiddenDirectories
        }
    }

    // MARK: - Patterns

    /// SwiftUI call sites that take a `LocalizedStringKey` or
    /// `LocalizedStringResource` as their first positional argument.
    /// Each entry is `(label, regex)` — the regex must match the
    /// call-site head ending right after `"…"` (without `comment:`).
    ///
    /// Patterns intentionally tolerate trailing whitespace and bind
    /// up through the next `,` or `)` — the absence of `comment:` in
    /// the trailing tail is the actual lint signal.
    ///
    /// The list grew organically as real catalogs were audited; new
    /// entries should mirror the SwiftUI API surface, not invent new
    /// ones. Each addition needs a positive + negative test fixture
    /// in `LocalizationAnalyzerTests`.
    private static let apis: [(String, String)] = [
        // Text / typography
        ("Text", #"\bText\(\s*"([^"]+)"\s*(\)|,)"#),
        ("Button", #"\bButton\(\s*"([^"]+)"\s*(\)|,)"#),
        ("Label", #"\bLabel\(\s*"([^"]+)"\s*,"#),
        // Controls
        ("Toggle", #"\bToggle\(\s*"([^"]+)"\s*,"#),
        ("Picker", #"\bPicker\(\s*"([^"]+)"\s*,"#),
        ("TextField", #"\bTextField\(\s*"([^"]+)"\s*,"#),
        ("SecureField", #"\bSecureField\(\s*"([^"]+)"\s*,"#),
        ("DatePicker", #"\bDatePicker\(\s*"([^"]+)"\s*,"#),
        ("Stepper", #"\bStepper\(\s*"([^"]+)"\s*,"#),
        ("ColorPicker", #"\bColorPicker\(\s*"([^"]+)"\s*,"#),
        // Containers / sections
        ("Section", #"\bSection\(\s*"([^"]+)"\s*(\)|,)"#),
        ("GroupBox", #"\bGroupBox\(\s*"([^"]+)"\s*(\)|,)"#),
        ("Menu", #"\bMenu\(\s*"([^"]+)"\s*(\)|,|\{)"#),
        // Navigation / links
        ("NavigationLink", #"\bNavigationLink\(\s*"([^"]+)"\s*,"#),
        ("Link", #"\bLink\(\s*"([^"]+)"\s*,"#),
        // View modifiers
        ("navigationTitle", #"\.navigationTitle\(\s*"([^"]+)"\s*\)"#),
        ("navigationSubtitle", #"\.navigationSubtitle\(\s*"([^"]+)"\s*\)"#),
        ("alert", #"\.alert\(\s*"([^"]+)"\s*,"#),
        ("confirmationDialog", #"\.confirmationDialog\(\s*"([^"]+)"\s*,"#),
        ("accessibilityLabel", #"\.accessibilityLabel\(\s*"([^"]+)"\s*\)"#),
        ("accessibilityHint", #"\.accessibilityHint\(\s*"([^"]+)"\s*\)"#),
        ("accessibilityValue", #"\.accessibilityValue\(\s*"([^"]+)"\s*\)"#),
        // Manual `String(localized:)` — flag when missing comment:.
        // Single-line only; multi-line wraps still bypass detection.
        ("String(localized:)", #"\bString\(\s*localized:\s*"([^"]+)"\s*\)"#),
    ]

    /// If a flagged line contains any of these substrings, treat as
    /// already-localized / verbatim / debug-only and skip. Note:
    /// `String(localized:` is intentionally NOT in this list — we
    /// want to detect missing-comment cases of that API too — so
    /// the per-call check relies on `comment:` being present on the
    /// line for legitimate uses.
    private static let skipMarkers = [
        "LocalizedStringResource(",
        "LocalizedStringKey(",
        "verbatim:",
        "comment:",
        "Logger(",
        ".log(",
        "print(",
        "assertionFailure(",
        "preconditionFailure(",
        "fatalError(",
        "Image(systemName:",
        "Image(\"",
        "URL(string:",
        "NSPredicate(format:",
        "Notification.Name(",
        "Bundle.main.localizedString(",
    ]

    // MARK: - Properties

    public let roots: [URL]
    public let configuration: Configuration

    // MARK: - Lifecycle

    public init(roots: [URL], configuration: Configuration = Configuration()) {
        self.roots = roots
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Walk the configured roots, scan every `.swift` file, return all
    /// detected issues. Files listed in `excludedFilenameSuffixes`
    /// (defaults to preview files) are skipped. Returns an empty
    /// array when no issues are found.
    public func analyze() throws -> [Issue] {
        var issues: [Issue] = []
        for root in roots {
            for file in try swiftFiles(rooted: root) {
                if shouldSkip(file: file) { continue }
                issues.append(contentsOf: try analyze(file: file))
            }
        }
        return issues
    }

    /// Scan a single file. Public to allow incremental scans (e.g.,
    /// the staged-files set inside a pre-commit hook).
    public func analyze(file: URL) throws -> [Issue] {
        let source = try String(contentsOf: file, encoding: .utf8)
        return analyze(file: file, source: source)
    }

    /// Pure-string variant for tests and pre-staged-content scans.
    public func analyze(file: URL, source: String) -> [Issue] {
        var issues: [Issue] = []
        var previewDepth = 0      // open braces inside the #Preview block
        var awaitingPreviewOpen = false  // saw #Preview but no `{` yet
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1
            let line = String(raw)

            // Track #Preview braces so we skip lines inside preview
            // blocks. Not a full parser — counts opening / closing
            // braces from the `#Preview` line onwards. A single-line
            // `#Preview { Text(...) }` ends the block on the same
            // line, so the next line is scanned normally.
            if line.contains("#Preview") {
                awaitingPreviewOpen = true
            }
            if awaitingPreviewOpen || previewDepth > 0 {
                let opens = line.filter { $0 == "{" }.count
                let closes = line.filter { $0 == "}" }.count
                if awaitingPreviewOpen && opens > 0 {
                    awaitingPreviewOpen = false
                    previewDepth = opens - closes
                } else {
                    previewDepth += opens - closes
                }
                if previewDepth < 0 { previewDepth = 0 }
                continue
            }

            // Escape hatch.
            if line.contains("// \(configuration.allowComment)") {
                continue
            }
            // Skip when the line already contains a localization
            // marker / debug-only construct.
            if Self.skipMarkers.contains(where: { line.contains($0) }) {
                continue
            }

            for (api, pattern) in Self.apis {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                regex.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
                    guard let match, match.numberOfRanges > 1 else { return }
                    guard let snippetRange = Range(match.range(at: 1), in: line) else { return }
                    let snippet = String(line[snippetRange])
                    let column = line.distance(from: line.startIndex, to: snippetRange.lowerBound) + 1
                    issues.append(
                        Issue(
                            file: file,
                            line: lineNumber,
                            column: column,
                            snippet: snippet,
                            api: api,
                            kind: .missingComment
                        )
                    )
                }
            }
        }
        return issues
    }

    // MARK: - Private

    private func shouldSkip(file: URL) -> Bool {
        let name = file.lastPathComponent
        return configuration.excludedFilenameSuffixes.contains { name.hasSuffix($0) }
    }

    private func swiftFiles(rooted: URL) throws -> [URL] {
        // Single-file entry-point: the pre-commit hook passes the
        // staged files directly so the scan is incremental.
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: rooted.path, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue {
            return rooted.pathExtension == "swift" ? [rooted] : []
        }
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !configuration.scanHiddenDirectories {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }
        guard
            let enumerator = fm.enumerator(
                at: rooted,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: enumeratorOptions
            )
        else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            result.append(url)
        }
        return result
    }
}
