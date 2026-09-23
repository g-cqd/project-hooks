import Foundation
import Testing

/// Review finding PH-11: a linter that requires a configuration ran only when the repository root had one, so a
/// configuration inside a package was ignored.
struct NestedConfigurationTests {
    @Test
    func `a package's own configuration makes its files linted`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter(configuration: "Packages/Kit/.swiftlint.yml")
        try repository.write("Packages/Kit/Sources/Kit.swift", "let kit = BAD\n")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("Packages/Kit/Sources/Kit.swift:1:1: error: BAD content"))
    }

    @Test
    func `files that no configuration covers are skipped`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.installContentLinter(configuration: "Packages/Kit/.swiftlint.yml")
        try repository.write("Packages/Kit/Sources/Kit.swift", "let kit = 1\n")
        try repository.write("App/App.swift", "let app = BAD\n")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(run.output.contains("No SwiftLint config covers 1 file(s)"))
        #expect(
            try repository.contentLinterInputs()
                .map { URL(fileURLWithPath: $0).lastPathComponent } == ["Kit.swift"])
    }
}
