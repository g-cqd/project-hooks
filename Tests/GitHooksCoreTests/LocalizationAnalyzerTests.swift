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

    @Test("Text without comment is flagged")
    func textWithoutComment() {
        let source = #"Text("Hello")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "Text")
        #expect(issues.first?.snippet == "Hello")
        #expect(issues.first?.line == 1)
        #expect(issues.first?.kind == .missingComment)
    }

    @Test("Button without comment is flagged")
    func buttonWithoutComment() {
        let source = #"Button("Save") { save() }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "Button")
    }

    @Test("navigationTitle without comment is flagged")
    func navigationTitleWithoutComment() {
        let source = #".navigationTitle("Profile")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "navigationTitle")
    }

    @Test("Label first arg without comment is flagged")
    func labelWithoutComment() {
        let source = #"Label("Print", systemImage: "printer")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "Label" && $0.snippet == "Print" })
    }

    @Test("Multiple issues on multi-line input")
    func multipleIssues() {
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

    @Test("Text with comment passes")
    func textWithComment() {
        let source = #"Text("Hello", comment: "Greeting")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("verbatim: parameter passes")
    func verbatimPasses() {
        let source = #"Text(verbatim: "Hello")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("LocalizedStringResource wrapper passes")
    func lsrPasses() {
        let source = #"Text(LocalizedStringResource("Hello", comment: "x"))"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("Image(systemName:) is not flagged")
    func imageSystemName() {
        let source = #"Image(systemName: "checkmark")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("Logger calls are skipped")
    func loggerSkipped() {
        let source = #"logger.error("Failed to load")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    // MARK: - Escape hatch

    @Test("`// not-localized` suppresses the flag")
    func escapeHatchSuppresses() {
        let source = #"Text("Internal-only") // not-localized"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("Custom escape-hatch comment works")
    func customEscapeHatch() {
        let analyzer = LocalizationAnalyzer(
            roots: [],
            configuration: .init(allowComment: "dev-only")
        )
        let source = #"Text("Internal-only") // dev-only"#
        let issues = analyzer.analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    // MARK: - #Preview blocks

    @Test("#Preview block contents are skipped")
    func previewBlockSkipped() {
        let source = """
        #Preview {
            Text("Preview only")
            Button("Tap me") { }
        }
        """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("Code after #Preview block is still scanned")
    func resumeAfterPreview() {
        let source = """
        #Preview { Text("Hidden") }
        Text("Visible")
        """
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.snippet == "Visible")
    }

    // MARK: - Extended API surface (added after the Ful audit pass)

    @Test(".alert without comment is flagged")
    func alertWithoutComment() {
        let source = #".alert("Confirm Delete", isPresented: $show) { }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "alert" && $0.snippet == "Confirm Delete" })
    }

    @Test(".confirmationDialog without comment is flagged")
    func confirmationDialogWithoutComment() {
        let source = #".confirmationDialog("Are you sure?", isPresented: $show) { }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "confirmationDialog" && $0.snippet == "Are you sure?" })
    }

    @Test("Menu without comment is flagged")
    func menuWithoutComment() {
        let source = #"Menu("Options") { Button("X") { } }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "Menu" && $0.snippet == "Options" })
    }

    @Test("NavigationLink without comment is flagged")
    func navigationLinkWithoutComment() {
        let source = #"NavigationLink("Open", destination: detail)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "NavigationLink" && $0.snippet == "Open" })
    }

    @Test("Link without comment is flagged")
    func linkWithoutComment() {
        let source = #"Link("Privacy Policy", destination: url)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "Link" && $0.snippet == "Privacy Policy" })
    }

    @Test("SecureField without comment is flagged")
    func secureFieldWithoutComment() {
        let source = #"SecureField("Password", text: $pwd)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "SecureField" && $0.snippet == "Password" })
    }

    @Test("ColorPicker without comment is flagged")
    func colorPickerWithoutComment() {
        let source = #"ColorPicker("Accent", selection: $color)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "ColorPicker" && $0.snippet == "Accent" })
    }

    @Test("GroupBox without comment is flagged")
    func groupBoxWithoutComment() {
        let source = #"GroupBox("Summary") { }"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "GroupBox" && $0.snippet == "Summary" })
    }

    @Test(".accessibilityLabel literal is flagged")
    func accessibilityLabelLiteral() {
        let source = #".accessibilityLabel("Tap to refresh")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "accessibilityLabel" && $0.snippet == "Tap to refresh" })
    }

    @Test(".accessibilityLabel(Text(verbatim:)) passes")
    func accessibilityLabelVerbatimWrapped() {
        let source = #".accessibilityLabel(Text(verbatim: "\(value)"))"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test(".accessibilityHint literal is flagged")
    func accessibilityHintLiteral() {
        let source = #".accessibilityHint("Opens settings")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "accessibilityHint" && $0.snippet == "Opens settings" })
    }

    @Test(".navigationSubtitle literal is flagged")
    func navigationSubtitleLiteral() {
        let source = #".navigationSubtitle("Last refresh: now")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "navigationSubtitle" && $0.snippet == "Last refresh: now" })
    }

    // MARK: - String(localized:) detection

    @Test("String(localized:) without comment is flagged")
    func stringLocalizedNoComment() {
        let source = #"let title = String(localized: "Hello")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.contains { $0.api == "String(localized:)" && $0.snippet == "Hello" })
    }

    @Test("String(localized:) WITH comment passes")
    func stringLocalizedWithComment() {
        let source = #"let title = String(localized: "Hello", comment: "Greeting")"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }

    @Test("Text(String(localized:)) is detected via the String(localized:) pattern, not Text")
    func nestedStringLocalizedInsideText() {
        // Text() opens with `String(`, not `"`, so the Text regex
        // doesn't fire; the inner `String(localized:)` regex catches
        // the missing comment. Single match expected.
        let source = #"Text(String(localized: "Hello"))"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.count == 1)
        #expect(issues.first?.api == "String(localized:)")
    }

    @Test("NSPredicate format string is not flagged")
    func nsPredicateSkipped() {
        let source = #"NSPredicate(format: "name == %@", value)"#
        let issues = analyzer().analyze(file: fakeURL, source: source)
        #expect(issues.isEmpty)
    }
}
