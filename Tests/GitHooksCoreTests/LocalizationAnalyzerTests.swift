import Foundation
import GitHooksCore
import Testing

@Suite("LocalizationAnalyzer — missing-comment detection")
struct LocalizationAnalyzerTests {
    private let fakeURL = URL(fileURLWithPath: "/test/Fake.swift")

    private func analyzer() -> LocalizationAnalyzer {
        LocalizationAnalyzer(roots: [], configuration: LocalizationAnalyzer.Configuration())
    }

    // MARK: - Positive cases (should flag)

    @Test
    func `Text without comment is flagged`() {
        let source = #"Text("Hello")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "Text")
        #expect(issues.first?.snippet == "Hello")
        #expect(issues.first?.line == 1)
        #expect(issues.first?.kind == .missingComment)
    }

    @Test
    func `Button without comment is flagged`() {
        let source = #"Button("Save") { save() }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "Button")
    }

    @Test
    func `navigationTitle without comment is flagged`() {
        let source = #".navigationTitle("Profile")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "navigationTitle")
    }

    @Test
    func `Label first arg without comment is flagged`() {
        let source = #"Label("Print", systemImage: "printer")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "Label" && $0.snippet == "Print" })
    }

    @Test
    func `Multiple issues on multi-line input`() {
        let source = """
            Text("Hi")
            Button("Save") { }
            Section("Section")
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 3)
        #expect(issues.map(\.line) == [1, 2, 3])
    }

    // MARK: - Negative cases (should NOT flag)

    @Test
    func `Text with comment passes`() {
        let source = #"Text("Hello", comment: "Greeting")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `verbatim: parameter passes`() {
        let source = #"Text(verbatim: "Hello")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `LocalizedStringResource wrapper passes`() {
        let source = #"Text(LocalizedStringResource("Hello", comment: "x"))"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Image(systemName:) is not flagged`() {
        let source = #"Image(systemName: "checkmark")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Logger calls are skipped`() {
        let source = #"logger.error("Failed to load")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    // MARK: - Escape hatch

    @Test
    func `// not-localized suppresses the flag`() {
        let source = #"Text("Internal-only") // not-localized"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Custom escape-hatch comment works`() {
        let analyzer = LocalizationAnalyzer(
            roots: [],
            configuration: .init(allowComment: "dev-only"),
        )
        let source = #"Text("Internal-only") // dev-only"#
        let issues = analyzer.analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    // MARK: - #Preview blocks

    @Test
    func `#Preview block contents are skipped`() {
        let source = """
            #Preview {
                Text("Preview only")
                Button("Tap me") { }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Code after #Preview block is still scanned`() {
        let source = """
            #Preview { Text("Hidden") }
            Text("Visible")
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.snippet == "Visible")
    }

    // MARK: - Extended API surface (added after the Ful audit pass)

    @Test
    func `.alert without comment is flagged`() {
        let source = #".alert("Confirm Delete", isPresented: $show) { }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "alert" && $0.snippet == "Confirm Delete" })
    }

    @Test
    func `.confirmationDialog without comment is flagged`() {
        let source = #".confirmationDialog("Are you sure?", isPresented: $show) { }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "confirmationDialog" && $0.snippet == "Are you sure?" })
    }

    @Test
    func `Menu without comment is flagged`() {
        let source = #"Menu("Options") { Button("X") { } }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "Menu" && $0.snippet == "Options" })
    }

    @Test
    func `NavigationLink without comment is flagged`() {
        let source = #"NavigationLink("Open", destination: detail)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "NavigationLink" && $0.snippet == "Open" })
    }

    @Test
    func `Link without comment is flagged`() {
        let source = #"Link("Privacy Policy", destination: url)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "Link" && $0.snippet == "Privacy Policy" })
    }

    @Test
    func `SecureField without comment is flagged`() {
        let source = #"SecureField("Password", text: $pwd)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "SecureField" && $0.snippet == "Password" })
    }

    @Test
    func `ColorPicker without comment is flagged`() {
        let source = #"ColorPicker("Accent", selection: $color)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "ColorPicker" && $0.snippet == "Accent" })
    }

    @Test
    func `GroupBox without comment is flagged`() {
        let source = #"GroupBox("Summary") { }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "GroupBox" && $0.snippet == "Summary" })
    }

    @Test
    func `.accessibilityLabel literal is flagged`() {
        let source = #".accessibilityLabel("Tap to refresh")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "accessibilityLabel" && $0.snippet == "Tap to refresh" })
    }

    @Test
    func `.accessibilityLabel(Text(verbatim:)) passes`() {
        let source = #".accessibilityLabel(Text(verbatim: "\(value)"))"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `.accessibilityHint literal is flagged`() {
        let source = #".accessibilityHint("Opens settings")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "accessibilityHint" && $0.snippet == "Opens settings" })
    }

    @Test
    func `.navigationSubtitle literal is flagged`() {
        let source = #".navigationSubtitle("Last refresh: now")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "navigationSubtitle" && $0.snippet == "Last refresh: now" })
    }

    // MARK: - String(localized:) detection

    @Test
    func `String(localized:) without comment is flagged`() {
        let source = #"let title = String(localized: "Hello")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "String(localized:)" && $0.snippet == "Hello" })
    }

    @Test
    func `String(localized:) WITH comment passes`() {
        let source = #"let title = String(localized: "Hello", comment: "Greeting")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Text(String(localized:)) is detected via the String(localized:) pattern, not Text`() {
        // Text() opens with `String(`, not `"`, so the Text regex
        // doesn't fire; the inner `String(localized:)` regex catches
        // the missing comment. Single match expected.
        let source = #"Text(String(localized: "Hello"))"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "String(localized:)")
    }

    @Test
    func `NSPredicate format string is not flagged`() {
        let source = #"NSPredicate(format: "name == %@", value)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    // MARK: - bareStringReturn detection
    //
    // Added after the SyncStatusMonitor.displayText regression: bare
    // string literals returned from a `String`-typed property body
    // bypass localization at the *declaration* site, so every
    // `Text(monitor.status.displayText)` consumer downstream renders
    // verbatim English. The call-site rule misses this completely.

    @Test
    func `Bare literal in single-line String case body is flagged`() {
        let source = """
            var displayText: String {
                switch self {
                case .idle: "Ready"
                case .syncing: "Syncing..."
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.kind == .bareStringReturn })
        #expect(issues.map(\.snippet).sorted() == ["Ready", "Syncing..."])
    }

    @Test
    func `Bare literal in multi-line String case body is flagged`() {
        let source = """
            var displayText: String {
                switch self {
                case .idle:
                    "Ready"
                case .error(let message):
                    message
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        // Only `"Ready"` is a literal — `message` is an identifier.
        #expect(issues.count == 1)
        #expect(issues.first?.snippet == "Ready")
        #expect(issues.first?.kind == .bareStringReturn)
    }

    @Test
    func `Bare return literal in String function is flagged`() {
        let source = """
            func describe() -> String {
                if condition { return "Ready" }
                return "Done"
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 2)
        #expect(issues.map(\.snippet).sorted() == ["Done", "Ready"])
        #expect(issues.allSatisfy { $0.kind == .bareStringReturn })
    }

    @Test
    func `Single-line String property body literal is flagged`() {
        let source = #"var label: String { "Hello" }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.kind == .bareStringReturn && $0.snippet == "Hello" })
    }

    @Test
    func `String(localized:) inside String-returning scope passes`() {
        // Wrapped literal — the catalog lookup happens at the
        // `String(localized:)` call, not at the consumer. No bare
        // literal escapes the scope.
        let source = """
            var displayText: String {
                switch self {
                case .idle:
                    String(localized: "Ready", comment: "x")
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `LocalizedStringResource init inside LSR scope passes`() {
        let source = """
            var displayText: LocalizedStringResource {
                switch self {
                case .idle:
                    LocalizedStringResource("Ready", comment: "x")
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Bare literal in LocalizedStringResource-returning scope is flagged`() {
        // LSR scope without LSR(...) constructor — the bare literal
        // becomes the default value via ExpressibleByStringLiteral,
        // but skips the `comment:` annotation needed for translators.
        let source = """
            var displayText: LocalizedStringResource {
                switch self {
                case .idle: "Ready"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.kind == .bareStringReturn && $0.snippet == "Ready" })
    }

    @Test
    func `Bare literals outside a String-returning scope are NOT flagged by this rule`() {
        // The literal is in a `Vehicle`-returning function body — out
        // of scope for the new rule. (The call-site rules would
        // separately handle anything that's user-facing here.)
        let source = """
            func makeVehicle() -> Vehicle {
                let name = "Tesla"
                return Vehicle(name: name)
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.filter { $0.kind == .bareStringReturn }.isEmpty)
    }

    @Test
    func `Bare literal returned from non-String function is NOT flagged`() {
        let source = """
            func count() -> Int {
                return 42
            }
            func name() -> Foo {
                return Foo(name: "Bar")
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Scope ends correctly when braces close`() {
        // After the `String`-returning property closes, we should
        // stop flagging — the next function returns `Int` and its
        // `return "still-a-string-but-not-in-scope"` literal would
        // be a Swift error anyway, but the analyzer shouldn't claim
        // it as a localization issue.
        let source = """
            var first: String {
                return "Hi"
            }
            func unrelated() -> Int {
                let x = "not-user-facing"
                return 1
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.snippet == "Hi")
    }

    @Test
    func `Escape hatch suppresses bareStringReturn rule too`() {
        let source = """
            var displayText: String {
                switch self {
                case .idle: "Ready" // not-localized
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test
    func `Reproduces the SyncStatusMonitor displayText bug`() {
        // The exact regression that escaped Ful's localization passes.
        // Five cases, four bare literals, one identifier passthrough.
        let source = """
            var displayText: String {
                switch self {
                    case .idle:
                        "Ready"
                    case .syncing:
                        "Syncing..."
                    case .synced(let date):
                        "Synced \\(date.formatted(.relative(presentation: .named)))"
                    case .error(let message):
                        message
                    case .noAccount:
                        "iCloud unavailable"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
            .filter { $0.kind == .bareStringReturn }
        #expect(issues.count == 4)
        let snippets = Set(issues.map(\.snippet))
        #expect(snippets.contains("Ready"))
        #expect(snippets.contains("Syncing..."))
        #expect(snippets.contains("iCloud unavailable"))
        // The interpolated `"Synced \(date...)"` case is flagged too —
        // interpolation doesn't change the verbatim-display problem.
        #expect(snippets.contains { $0.hasPrefix("Synced ") })
    }

    // MARK: - bareStringReturn skip-list (non-user-facing scopes)

    @Test
    func `Property named icon is skipped wholesale`() {
        // SF Symbol names are the canonical example: every case body
        // is a bare literal but none are user-facing — they feed
        // Image(systemName:).
        let source = """
            var icon: String {
                switch self {
                case .idle: "checkmark.icloud"
                case .syncing: "arrow.triangle.2.circlepath.icloud"
                case .error: "exclamationmark.icloud"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.filter { $0.kind == .bareStringReturn }.isEmpty)
    }

    @Test
    func `Property named id is skipped wholesale`() {
        let source = """
            var id: String {
                switch self {
                case .cloud: "cloud-current"
                case .local: "local-swiftdata"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.filter { $0.kind == .bareStringReturn }.isEmpty)
    }

    @Test
    func `Identifier-shaped literals are skipped in non-skipped scope`() {
        // Property name is `category` — which IS skipped. But even
        // for an unskipped name like `someText: String`, an
        // SF-Symbol-shaped literal still gets the identifier shape
        // filter. Verifies the shape filter works independently.
        let source = """
            var someText: String {
                switch self {
                case .a: "some.identifier.shape"
                case .b: "actual user-facing text"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
            .filter { $0.kind == .bareStringReturn }
        #expect(issues.count == 1)
        #expect(issues.first?.snippet == "actual user-facing text")
    }

    @Test
    func `Function name systemImage is skipped`() {
        let source = """
            func systemImage(for item: Item) -> String {
                switch item {
                case .a: return "star.fill"
                case .b: return "circle"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.filter { $0.kind == .bareStringReturn }.isEmpty)
    }

    @Test
    func `Reproduces the NetworkMonitor ConnectionType displayName bug`() {
        let source = """
            public var displayName: String {
                switch self {
                    case .wifi: "Wi-Fi"
                    case .cellular: "Cellular"
                    case .ethernet: "Ethernet"
                    case .unknown: "Unknown"
                }
            }
            """
        let issues = analyzer().analyze(file: fakeURL, source: source)
            .filter { $0.kind == .bareStringReturn }
        #expect(issues.count == 4)
        let snippets = Set(issues.map(\.snippet))
        #expect(snippets == ["Wi-Fi", "Cellular", "Ethernet", "Unknown"])
    }
}
