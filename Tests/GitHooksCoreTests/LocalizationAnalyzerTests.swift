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
}
