import Foundation
import Testing

/// Review finding PH-6, from the review of the fix: the hook's own interpreter, the commands that project-hooks runs,
/// and the path that `install` embeds must not come from the repository either.
struct HookPathSafetyTests {
    @Test
    func `install run by name through PATH embeds the binary's own path`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let installed = repository.scratch.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: ProjectHooksBinary.path,
            toPath: installed.appendingPathComponent("project-hooks").path,
        )
        var environment = repository.environment
        environment["PATH"] = "\(installed.path):/usr/bin:/bin"

        let run = try runProcess(
            ["/bin/bash", "-c", "project-hooks install"],
            in: repository.root,
            environment: environment,
        )
        let hook = try repository.read(".git/hooks/pre-commit")

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(hook.contains("/installed/project-hooks'"), "\(hook)")
        #expect(!hook.contains("\(repository.path)/project-hooks"))
    }

    @Test
    func `a relative PATH entry cannot substitute the hook's interpreter or its git`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        for program in ["bash", "git", "env"] {
            let marker = repository.scratch.appendingPathComponent("repository-\(program)-ran").path
            try repository.write(program, "#!/bin/sh\ntouch '\(marker)'\nexit 1\n", executable: true)
        }
        try repository.write("notes.txt", "notes\n")
        try repository.installHooks()
        try repository.git("add", "notes.txt")
        var environment = repository.environment
        environment["PATH"] = ".:" + (environment["PATH"] ?? "")

        let commit = try runProcess(
            ["/usr/bin/git", "commit", "-q", "-m", "Add notes"],
            in: repository.root,
            environment: environment,
        )

        #expect(commit.exitCode == 0, "\(commit.output)")
        for program in ["bash", "git", "env"] {
            #expect(!repository.scratchExists("repository-\(program)-ran"), "the repository's \(program) ran")
        }
    }
}
