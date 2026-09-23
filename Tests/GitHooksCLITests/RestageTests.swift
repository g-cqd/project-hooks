import Foundation
import Testing

/// Review finding PH-4: `restage` staged whole files, so it committed hunks that the user had left unstaged.
struct RestageTests {
    @Test
    func `a restaging task does not run while its files have unstaged changes`() throws {
        let repository =
            try makeRepository(task: "run: \"touch task-ran\"\n      on-files: [\"*.txt\"]\n      restage: true")
        defer { repository.remove() }
        try repository.write("notes.txt", "staged\n")
        try repository.git("add", "notes.txt")
        try repository.write("notes.txt", "staged\nnot for this commit\n")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("restages files that have unstaged changes"))
        #expect(!repository.exists("task-ran"))
        #expect(try repository.git("show", ":notes.txt") == "staged")
    }

    @Test
    func `configured restage paths with unstaged changes block too`() throws {
        let repository = try makeRepository(task: "run: \"true\"\n      restage: [\"LICENSES.txt\"]")
        defer { repository.remove() }
        try repository.write("LICENSES.txt", "edited, not staged\n")
        try repository.write("notes.txt", "staged\n")
        try repository.git("add", "notes.txt")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(try repository.git("show", ":LICENSES.txt") == "original")
    }

    @Test
    func `a formatter's changes are restaged when nothing else was unstaged`() throws {
        let repository = try makeRepository(
            task: "run: \"sed -i '' 's/messy/tidy/' notes.txt\"\n      on-files: [\"*.txt\"]\n      restage: true",
        )
        defer { repository.remove() }
        try repository.write("notes.txt", "messy\n")
        try repository.git("add", "notes.txt")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(try repository.git("show", ":notes.txt") == "tidy")
    }

    /// A trusted repository with one committed LICENSES.txt and a pre-commit task with the given YAML fields.
    private func makeRepository(task fields: String, name: String = #function) throws -> ScratchRepository {
        let repository = try ScratchRepository.make(name)
        try repository.write(
            ".project-hooks.yml",
            "pre-commit:\n  tasks:\n    - name: \"Restaging task\"\n      \(fields)\n",
        )
        try repository.write("LICENSES.txt", "original\n")
        try repository.commitAll("Add a restaging task")
        try repository.trust()
        return repository
    }
}
