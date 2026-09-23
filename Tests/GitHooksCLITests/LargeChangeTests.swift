import Foundation
import Testing

/// Foundation's `Process` refuses a command with more than 4096 arguments by raising an exception, which ended the
/// hook.
///
/// Linters that take one argument per file, and restaging, received every file at once.
struct LargeChangeTests {
    private static let fileCount = 5000

    @Test
    func `a lint group with thousands of files is linted in batches`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let log = repository.scratch.appendingPathComponent("swiftformat-arguments")
        try repository.installTool("swiftformat", script: "#!/bin/sh\necho $# >> '\(log.path)'\nexit 0\n")
        try repository.write(".swiftformat", "--indent 4\n")
        try writeFiles(in: repository)
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])
        let argumentCounts = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }

        #expect(run.exitCode == 0, "\(run.output.suffix(500))")
        #expect(argumentCounts.allSatisfy { $0 <= 4096 }, "\(argumentCounts)")
        #expect(argumentCounts.reduce(0, +) >= Self.fileCount)
    }

    @Test
    func `a task that restages thousands of files restages them in batches`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(
            ".project-hooks.yml",
            "pre-commit:\n  tasks:\n    - name: \"Touch\"\n      run: \"true\"\n      on-files: [\"*.txt\"]\n      restage: true\n",
        )
        try repository.commitAll("Add a restaging task")
        try repository.trust()
        try writeFiles(in: repository, extension: "txt")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output.suffix(500))")
        #expect(try repository.git("diff", "--cached", "--name-only").split(separator: "\n").count == Self.fileCount)
    }

    private func writeFiles(in repository: ScratchRepository, extension fileExtension: String = "swift") throws {
        let directory = repository.root.appendingPathComponent("Sources/Generated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<Self.fileCount {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("File\(index).\(fileExtension)").path,
                contents: Data("let value = \(index)\n".utf8),
            )
        }
    }
}
