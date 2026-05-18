import Foundation

/// Static analyser that flags SwiftUI string-literal call sites missing.
///
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
            /// A bare `"…"` literal is returned from a `String` /
            /// `LocalizedStringResource` scope without going through
            /// `String(localized:)` or `LocalizedStringResource(_:comment:)`.
            ///
            /// The original Ful audit missed `SyncStatusMonitor.displayText`
            /// because the literal was the body of a switch-case inside a
            /// `String`-returning computed property — every consumer was
            /// already wrapped (`Text(status.displayText)`) but `Text`
            /// picks the verbatim `StringProtocol` overload for `String`,
            /// so the catalog lookup never happens. This rule lints the
            /// declaration site instead of the call site.
            case bareStringReturn
        }

        public let file: URL
        public let line: Int  // 1-indexed
        public let column: Int  // 1-indexed, byte offset
        public let snippet: String
        public let api: String  // e.g. "Text", "Button"
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
            switch kind {
                case .missingComment:
                    "\(file.path):\(line):\(column): warning: \(api) literal missing `comment:` — \(snippet)"
                case .bareStringReturn:
                    "\(file.path):\(line):\(column): warning: bare string literal returned from \(api) scope — wrap in `String(localized:comment:)` or change the return type to `LocalizedStringResource` — \(snippet)"
            }
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
            scanHiddenDirectories: Bool = false,
        ) {
            self.allowComment = allowComment
            self.excludedFilenameSuffixes = excludedFilenameSuffixes
            self.scanHiddenDirectories = scanHiddenDirectories
        }
    }

    // MARK: - Patterns

    /// SwiftUI call sites that take a `LocalizedStringKey` or.
    ///
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

    /// If a flagged line contains any of these substrings, treat as.
    ///
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

    /// Walk the configured roots, scan every `.swift` file, return all.
    ///
    /// detected issues. Files listed in `excludedFilenameSuffixes`
    /// (defaults to preview files) are skipped. Returns an empty
    /// array when no issues are found.
    public func analyze() throws -> [Issue] {
        var issues: [Issue] = []
        for root in roots {
            for file in try swiftFiles(rooted: root) {
                if shouldSkip(file: file) { continue }
                try issues.append(contentsOf: analyze(file: file))
            }
        }
        return issues
    }

    /// Scan a single file.
    ///
    /// Public to allow incremental scans (e.g.,
    /// the staged-files set inside a pre-commit hook).
    public func analyze(file: URL) throws -> [Issue] {
        let source = try String(contentsOf: file, encoding: .utf8)
        return analyze(file: file, source: source)
    }

    /// Pure-string variant for tests and pre-staged-content scans.
    public func analyze(file: URL, source: String) -> [Issue] {
        var issues: [Issue] = []
        var previewDepth = 0  // open braces inside the #Preview block
        var awaitingPreviewOpen = false  // saw #Preview but no `{` yet

        // Scope tracker for the `bareStringReturn` rule: depth of
        // `{ ... }` nesting *inside* the closest enclosing function /
        // property that returns `String` or `LocalizedStringResource`.
        // 0 → not currently inside such a scope. Nested scopes
        // (nested closures, switch blocks) increment the depth via
        // brace counts on each line; the scope ends when depth
        // returns to 0.
        var localizableScopeKind: String? = nil  // "String" or "LocalizedStringResource"
        var localizableScopeDepth = 0
        var localizableScopeDeclName: String? = nil  // the property/function name that opened the scope
        // True when the previous line ended with `case .foo:` (or
        // `case .foo, .bar:`) and we expect the case body to land on
        // the next line. Multi-line case bodies are the second half
        // of the single-line `case .foo: "lit"` pattern.
        var awaitingLiteralAfterCase = false

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
                let opens = line.count(where: { $0 == "{" })
                let closes = line.count(where: { $0 == "}" })
                if awaitingPreviewOpen, opens > 0 {
                    awaitingPreviewOpen = false
                    previewDepth = opens - closes
                } else {
                    previewDepth += opens - closes
                }
                if previewDepth < 0 { previewDepth = 0 }
                continue
            }

            // Escape hatch — applies to BOTH detection rules.
            let escapeHatchPresent = line.contains("// \(configuration.allowComment)")

            // Bare-literal-in-localizable-scope rule.
            // Runs BEFORE the skip-markers gate because some of the
            // skip markers (`LocalizedStringResource(`, `String(localized:`)
            // are precisely how callers *correctly* wrap literals inside
            // the scope — those lines should pass this rule without
            // also being scanned for the call-site rule.
            if !escapeHatchPresent {
                detectBareStringReturn(
                    file: file,
                    line: line,
                    lineNumber: lineNumber,
                    localizableScopeKind: &localizableScopeKind,
                    localizableScopeDepth: &localizableScopeDepth,
                    localizableScopeDeclName: &localizableScopeDeclName,
                    awaitingLiteralAfterCase: &awaitingLiteralAfterCase,
                    issues: &issues,
                )
            } else if localizableScopeDepth > 0 {
                // Still need to update depth so the scope ends correctly.
                let opens = line.count(where: { $0 == "{" })
                let closes = line.count(where: { $0 == "}" })
                localizableScopeDepth += opens - closes
                if localizableScopeDepth <= 0 {
                    localizableScopeDepth = 0
                    localizableScopeKind = nil
                    localizableScopeDeclName = nil
                    awaitingLiteralAfterCase = false
                }
            }

            if escapeHatchPresent {
                continue
            }
            // Skip when the line already contains a localization
            // marker / debug-only construct.
            if Self.skipMarkers.contains(where: { line.contains($0) }) {
                continue
            }

            for (api, pattern) in Self.apis {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
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
                            kind: .missingComment,
                        ),
                    )
                }
            }
        }
        return issues
    }

    // MARK: - bareStringReturn detection

    /// Property / function names whose bodies are non-user-facing by
    /// convention and should be skipped wholesale. SF Symbol names,
    /// log subsystem / category strings, storage keys, and other
    /// internal identifiers live in these slots and the cost of
    /// hand-wrapping every one in `String(localized:)` outweighs the
    /// signal. The list mirrors the recurring names that surfaced in
    /// the Ful audit — extend conservatively.
    private static let nonUserFacingDeclNames: Set<String> = [
        "icon", "iconName",
        "imageName", "systemName", "systemImage", "systemImageName",
        "id", "identifier",
        "key", "storageKey", "cacheKey",
        "category", "subsystem", "tag",
        "rawValue",
        "csvHeader", "columnHeader",
        "path", "filename", "fileExtension",
    ]

    /// Literals that look like pure identifiers — SF Symbols
    /// (`chart.bar.fill`), hyphenated IDs (`cloud-current`). These
    /// are non-user-facing by shape and would be a hand-wrapping
    /// treadmill if flagged.
    ///
    /// Identifier shape:
    ///   - ASCII only (no diacritics, no CJK — those are human text)
    ///   - Only `[A-Za-z0-9._\-]` (no whitespace or natural-language
    ///     punctuation like `?`, `:`, `!`)
    ///   - Contains at least one delimiter (`.`, `-`, `_`)
    ///   - All lowercase (`Wi-Fi`, `Ready`, `Cellular` retain
    ///     uppercase and stay user-facing)
    ///
    /// Single-word literals (no delimiter) — even all-lowercase like
    /// `debug` or all-caps like `ERROR` — are intentionally NOT
    /// filtered here. They're handled by the declaration-name skip
    /// list when present in `category` / `subsystem` / `tag` scopes,
    /// and surface as legitimate issues otherwise.
    private static func looksLikeIdentifier(_ literal: String) -> Bool {
        guard !literal.isEmpty else { return false }
        var hasDelimiter = false
        var hasUppercase = false
        for scalar in literal.unicodeScalars {
            if scalar.value >= 0x80 { return false }
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase { hasUppercase = true }
                continue
            }
            if ch == "." || ch == "_" || ch == "-" {
                hasDelimiter = true
                continue
            }
            return false
        }
        return hasDelimiter && !hasUppercase
    }

    /// Open / close a `String`-returning scope based on the contents of `line`.
    ///
    /// Detects `: String {`, `-> String {`, `: LocalizedStringResource {`,
    /// `-> LocalizedStringResource {` headers and starts tracking the
    /// body. Inside the body, three patterns surface bare literals:
    ///
    ///   1. `case .foo: "lit"` — single-line switch case body.
    ///   2. `case .foo:` followed by a `"lit"`-only next line — multi-line.
    ///   3. `return "lit"` — explicit return.
    ///
    /// Bare literals wrapped by `String(localized:`, `LocalizedStringResource(`,
    /// or `LocalizedStringKey(` on the same line are not flagged — the
    /// pattern only matches a `"` that immediately follows `:` or `return `.
    private func detectBareStringReturn(
        file: URL,
        line: String,
        lineNumber: Int,
        localizableScopeKind: inout String?,
        localizableScopeDepth: inout Int,
        localizableScopeDeclName: inout String?,
        awaitingLiteralAfterCase: inout Bool,
        issues: inout [Issue],
    ) {
        // 1) Detect scope opening before we update brace depth — the
        //    opening line counts its own `{` toward the scope body.
        if localizableScopeDepth == 0 {
            if let kind = Self.matchedScopeKind(in: line) {
                let declName = Self.matchedDeclName(in: line)
                let skipWholeScope =
                    declName.map { Self.nonUserFacingDeclNames.contains($0) } ?? false
                if skipWholeScope {
                    // Still track depth so we know when the scope
                    // ends — otherwise nested braces would confuse
                    // the next scope detection.
                    localizableScopeKind = kind
                    localizableScopeDeclName = declName
                    let opens = line.count(where: { $0 == "{" })
                    let closes = line.count(where: { $0 == "}" })
                    localizableScopeDepth = opens - closes
                    if localizableScopeDepth <= 0 {
                        localizableScopeKind = nil
                        localizableScopeDeclName = nil
                        localizableScopeDepth = 0
                    }
                    return
                }
                localizableScopeKind = kind
                localizableScopeDeclName = declName
                // Treat the opening `{` as the scope's depth-1 boundary.
                // Any further braces on the same line nest inside.
                let opens = line.count(where: { $0 == "{" })
                let closes = line.count(where: { $0 == "}" })
                localizableScopeDepth = opens - closes
                if localizableScopeDepth > 0 {
                    // Still scan THIS line for bare-literal patterns
                    // (single-line `var foo: String { "Hi" }` form).
                    flagBareLiterals(
                        in: line,
                        file: file,
                        lineNumber: lineNumber,
                        kindName: kind,
                        awaitingLiteralAfterCase: &awaitingLiteralAfterCase,
                        issues: &issues,
                    )
                } else {
                    // Opens and closes on the same line at the same
                    // depth — single-line body, scan then close.
                    flagBareLiterals(
                        in: line,
                        file: file,
                        lineNumber: lineNumber,
                        kindName: kind,
                        awaitingLiteralAfterCase: &awaitingLiteralAfterCase,
                        issues: &issues,
                    )
                    localizableScopeKind = nil
                    localizableScopeDeclName = nil
                    localizableScopeDepth = 0
                    awaitingLiteralAfterCase = false
                }
            }
            return
        }

        // 2) Already inside a scope — scan first, then update depth.
        if localizableScopeDeclName.map({ Self.nonUserFacingDeclNames.contains($0) }) != true {
            let kindName = localizableScopeKind ?? "String"
            flagBareLiterals(
                in: line,
                file: file,
                lineNumber: lineNumber,
                kindName: kindName,
                awaitingLiteralAfterCase: &awaitingLiteralAfterCase,
                issues: &issues,
            )
        }

        let opens = line.count(where: { $0 == "{" })
        let closes = line.count(where: { $0 == "}" })
        localizableScopeDepth += opens - closes
        if localizableScopeDepth <= 0 {
            localizableScopeDepth = 0
            localizableScopeKind = nil
            localizableScopeDeclName = nil
            awaitingLiteralAfterCase = false
        }
    }

    /// Extract the declaration name from a scope-opening line.
    ///
    /// Matches the `name` in `var name: String {`, `let name: String =`,
    /// `func name() -> String {`, `private public ... var name: String {`.
    /// Used by the `nonUserFacingDeclNames` skip filter — when the
    /// name says "icon" / "id" / "key", the body holds non-user-facing
    /// identifiers and the rule should stay quiet.
    private static func matchedDeclName(in line: String) -> String? {
        let patterns = [
            #"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:String|LocalizedStringResource)\b"#,
            #"\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:String|LocalizedStringResource)\b"#,
            #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?:async\s+)?(?:throws\s+)?->\s*(?:String|LocalizedStringResource)\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, options: [], range: range),
                match.numberOfRanges > 1,
                let nameRange = Range(match.range(at: 1), in: line)
            {
                return String(line[nameRange])
            }
        }
        return nil
    }

    /// Pattern set for the `bareStringReturn` rule. Match group 1 is
    /// the bare literal. Each pattern intentionally anchors the
    /// literal immediately after a `:` (switch case body) or `return `
    /// keyword, so wrapped forms like `case .foo: String(localized: "…")`
    /// don't match (the `"…"` no longer abuts `:`).
    private static let bareReturnPatterns: [(String, String)] = [
        // `case .foo: "literal"` — single-line case body.
        // `[^:{]+?` keeps the match anchored to a single `case` head
        // and refuses to swallow trailing `:` or `{`.
        ("switch case", #"\bcase\s+[^:{\n]+?:\s*"([^"]+)"\s*$"#),
        // `return "literal"` — explicit return.
        ("return", #"\breturn\s+"([^"]+)""#),
        // Single-line body: `var foo: String { "literal" }` and
        // single-line getter `{ get { "literal" } }`. Anchored on
        // the literal sitting alone between braces / between `{` and
        // a closing `}` later in the line.
        ("single-line body", #"\{\s*"([^"]+)"\s*\}"#),
    ]

    private func flagBareLiterals(
        in line: String,
        file: URL,
        lineNumber: Int,
        kindName: String,
        awaitingLiteralAfterCase: inout Bool,
        issues: inout [Issue],
    ) {
        // Multi-line case: the previous line ended with `case … :`
        // and this line is just `"literal"`.
        if awaitingLiteralAfterCase {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let snippet = Self.standaloneLiteral(in: trimmed),
                !Self.looksLikeIdentifier(snippet)
            {
                let column = (line.range(of: "\"")?.lowerBound).map {
                    line.distance(from: line.startIndex, to: $0) + 1
                } ?? 1
                issues.append(
                    Issue(
                        file: file,
                        line: lineNumber,
                        column: column,
                        snippet: snippet,
                        api: "\(kindName)-returning scope",
                        kind: .bareStringReturn,
                    ),
                )
            }
            awaitingLiteralAfterCase = false
        }

        // Each line-level pattern (case body / return / single-line
        // body). The patterns refuse to swallow trailing `,` so
        // they never collide with the call-site rule's matches.
        // Identifier-shaped literals (SF Symbols, storage keys, log
        // categories) are filtered post-match — they're indistinguishable
        // from user-facing text in regex but trivial to recognise by
        // character class.
        for (subKind, pattern) in Self.bareReturnPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            regex.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                guard let snippetRange = Range(match.range(at: 1), in: line) else { return }
                let snippet = String(line[snippetRange])
                if Self.looksLikeIdentifier(snippet) { return }
                let column = line.distance(from: line.startIndex, to: snippetRange.lowerBound) + 1
                issues.append(
                    Issue(
                        file: file,
                        line: lineNumber,
                        column: column,
                        snippet: snippet,
                        api: "\(kindName)-returning scope (\(subKind))",
                        kind: .bareStringReturn,
                    ),
                )
            }
        }

        // Multi-line case detection: did THIS line end with `case … :`?
        // Tolerate trailing whitespace and a `// comment` tail.
        let trimmedTail = Self.strippingTrailingLineComment(from: line)
            .trimmingCharacters(in: .whitespaces)
        if let regex = try? NSRegularExpression(pattern: #"\bcase\b[^:{\n]+:$"#),
            regex.firstMatch(in: trimmedTail, options: [], range: NSRange(location: 0, length: trimmedTail.utf16.count))
                != nil
        {
            awaitingLiteralAfterCase = true
        }
    }

    /// Returns `"String"` / `"LocalizedStringResource"` when `line`
    /// opens a scope of either type. Detects both the property form
    /// (`: String {`) and the function-return form (`-> String {`).
    private static func matchedScopeKind(in line: String) -> String? {
        // Property/function header followed by `{` on the same line.
        // Most real declarations open the brace on the same line as
        // the signature — Swift style. Headers that split across
        // lines (rare) fall back to next-line detection on the brace
        // line itself, which our patterns don't match — known limit,
        // accept the false-negative for now.
        let patterns: [(String, String)] = [
            ("LocalizedStringResource", #":\s*LocalizedStringResource\s*\{|->\s*LocalizedStringResource\s*\{"#),
            ("String", #":\s*String\s*\{|->\s*String\s*\{"#),
        ]
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                return kind
            }
        }
        return nil
    }

    /// If `text` is exactly a single `"…"` literal (possibly with a
    /// trailing comment), return the inner snippet. Used by the
    /// multi-line case rule, where the previous line ended on `case …:`
    /// and the body is a literal on its own line.
    private static func standaloneLiteral(in text: String) -> String? {
        let stripped = strippingTrailingLineComment(from: text)
            .trimmingCharacters(in: .whitespaces)
        guard stripped.hasPrefix("\""), stripped.hasSuffix("\""), stripped.count >= 2 else {
            return nil
        }
        let inner = String(stripped.dropFirst().dropLast())
        // Reject anything that contains an unescaped `"` — that's not
        // a single literal, it's an expression that happens to start
        // with one.
        if inner.contains("\"") { return nil }
        return inner
    }

    /// Strip a trailing `//` line comment, respecting `//` that appears
    /// inside a string literal. Best-effort: counts unescaped `"` to
    /// decide whether we're inside a literal at the `//` position.
    private static func strippingTrailingLineComment(from line: String) -> String {
        var inString = false
        var prevWasEscape = false
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\\", inString {
                prevWasEscape.toggle()
            } else if ch == "\"", !prevWasEscape {
                inString.toggle()
                prevWasEscape = false
            } else if !inString, ch == "/", line.index(after: index) < line.endIndex,
                line[line.index(after: index)] == "/"
            {
                return String(line[..<index])
            } else {
                prevWasEscape = false
            }
            index = line.index(after: index)
        }
        return line
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
                options: enumeratorOptions,
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
