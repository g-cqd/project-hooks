import GitHooksCore
import Testing

struct LintOutcomeTests {
    @Test(arguments: [
        ("SwiftLint", Int32(0), "", LintOutcome.passed),
        ("SwiftLint", 2, "", .violations),
        ("SwiftLint", 1, "Error: No lintable files found at paths: ''", .allFilesExcluded),
        ("SwiftLint", 1, "Error: something else", .failed(exitCode: 1)),
        ("SwiftLint", 64, "Error: Unknown option '--bogus'", .failed(exitCode: 64)),
        ("SwiftLint", 134, "", .failed(exitCode: 134)),
        ("swift-format", 1, "", .violations),
        (
            "swift-format", 1, "error: Unable to read configuration: missing key `orderedImports.shouldGroupImports`",
            .failed(exitCode: 1)
        ),
        ("swift-format", 64, "", .failed(exitCode: 64)),
        ("SwiftFormat", 1, "", .violations),
        ("SwiftFormat", 70, "", .failed(exitCode: 70)),
        ("ktlint", 1, "", .violations),
        ("detekt", 2, "", .violations),
        ("detekt", 1, "", .failed(exitCode: 1)),
        ("detekt", 3, "", .failed(exitCode: 3)),
        ("unknown", 1, "", .failed(exitCode: 1)),
    ])
    func `classifies each linter's exit code`(linter: String, exitCode: Int32, output: String, expected: LintOutcome) {
        #expect(LintOutcome.classify(linterName: linter, exitCode: exitCode, output: output) == expected)
    }

    @Test
    func `only a clean run or fully excluded files let the commit through`() {
        #expect(LintOutcome.passed.passes)
        #expect(LintOutcome.allFilesExcluded.passes)
        #expect(!LintOutcome.violations.passes)
        #expect(!LintOutcome.failed(exitCode: 64).passes)
        #expect(!LintOutcome.timedOut.passes)
    }
}

struct LintConfigurationTests {
    @Test
    func `SwiftLint includes are local parent and child configurations`() {
        let yaml = """
            parent_config: ../base.yml
            child_config: strict.yml
            only_rules:
              - force_cast
            """

        #expect(LintConfiguration.swiftLintReferences(in: yaml) == ["../base.yml", "strict.yml"])
    }

    @Test
    func `remote SwiftLint includes are left to SwiftLint`() {
        #expect(LintConfiguration.swiftLintReferences(in: "parent_config: https://example.com/base.yml\n").isEmpty)
    }

    @Test(arguments: ["", "- not a mapping\n", "parent_config: [1, 2]\n"])
    func `a configuration without includes has none`(yaml: String) {
        #expect(LintConfiguration.swiftLintReferences(in: yaml).isEmpty)
    }

    @Test
    func `configuration file names include every linter's and .swift-version`() {
        #expect(
            LintConfiguration.fileNames.isSuperset(of: [
                ".swiftlint.yml", ".swiftlint.yaml", ".swiftformat", ".swift-format", ".editorconfig", "detekt.yml",
                ".swift-version",
            ]))
    }
}
