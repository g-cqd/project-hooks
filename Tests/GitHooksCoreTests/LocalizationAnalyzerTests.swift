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

    @Test("String(localized:) wrapper passes")
    func stringLocalizedPasses() {
        let source = #"Text(String(localized: "Hello"))"#
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
}
