import Foundation
import Testing

/// Review finding PH-6: under a global install, every clone runs project-hooks, so a repository's own code must not
/// run until the user trusts it.
struct RepositoryTrustTests {
    /// Tasks and a test override that leave a marker in `directory` when they run.
    ///
    /// Pre-push tasks and tests run in a temporary worktree, so the markers go outside the repository.
    private static func taskConfig(markers directory: URL) -> String {
        """
        pre-commit:
          tasks:
            - name: "Repository task"
              run: "touch '\(directory.path)/pre-commit-task-ran'"
        pre-push:
          tasks:
            - name: "Repository task"
              run: "touch '\(directory.path)/pre-push-task-ran'"
          test-override:
            type: gradle
        """
    }

    /// A Gradle wrapper that the repository ships, which the test override runs.
    private static func gradleWrapper(markers directory: URL) -> String {
        "#!/bin/sh\ntouch '\(directory.path)/gradle-wrapper-ran'\n"
    }

    @Test
    func `an untrusted repository's commit tasks do not run`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", Self.taskConfig(markers: repository.scratch))
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!repository.scratchExists("pre-commit-task-ran"))
        #expect(run.output.contains("project-hooks trust"))
    }

    @Test
    func `an untrusted repository's push tasks, builds and tests do not run`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", Self.taskConfig(markers: repository.scratch))
        try repository.write("gradlew", Self.gradleWrapper(markers: repository.scratch), executable: true)
        let head = try repository.commitAll("Add a task and a test override")

        let run = try repository.runPrePush(localSHA: head)

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!repository.scratchExists("pre-push-task-ran"))
        #expect(!repository.scratchExists("gradle-wrapper-ran"))
        #expect(run.output.contains("Skipped tests and builds"))
    }

    @Test
    func `a trusted repository's tasks, builds and tests run`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", Self.taskConfig(markers: repository.scratch))
        try repository.write("gradlew", Self.gradleWrapper(markers: repository.scratch), executable: true)
        let head = try repository.commitAll("Add a task and a test override")
        try repository.trust()

        let commit = try repository.runProjectHooks(["pre-commit"])
        try repository.write("staged.txt", "staged\n")
        try repository.git("add", "staged.txt")
        let commitWithChanges = try repository.runProjectHooks(["pre-commit"])
        let push = try repository.runPrePush(localSHA: head)

        #expect(commit.exitCode == 0 && commitWithChanges.exitCode == 0 && push.exitCode == 0, "\(push.output)")
        #expect(repository.scratchExists("pre-commit-task-ran"))
        #expect(repository.scratchExists("pre-push-task-ran"))
        #expect(repository.scratchExists("gradle-wrapper-ran"))
        #expect(!push.output.contains("project-hooks trust"))
    }

    @Test
    func `a skipped test stage is not reported as skipped for trust`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", "pre-push:\n  test-override:\n    type: gradle\n    skip: true\n")
        try repository.write("notes.txt", "notes\n")
        let head = try repository.commitAll("Skip tests")

        let run = try repository.runPrePush(localSHA: head)

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!run.output.contains("Skipped tests and builds"))
    }

    @Test
    func `the trust command records and revokes trust in the local configuration`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }

        let trust = try repository.runProjectHooks(["trust"])
        let recorded = try repository.git("config", "--local", "--get", "project-hooks.trusted")
        let revoke = try repository.runProjectHooks(["trust", "--revoke"])
        let revokeAgain = try repository.runProjectHooks(["trust", "--revoke"])

        #expect(trust.exitCode == 0, "\(trust.output)")
        #expect(recorded == "true")
        #expect(revoke.exitCode == 0 && revokeAgain.exitCode == 0, "\(revokeAgain.output)")
        #expect(throws: ScratchFailure.self) {
            try repository.git("config", "--local", "--get", "project-hooks.trusted")
        }
    }

    @Test
    func `an invalid trust value counts as untrusted`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", Self.taskConfig(markers: repository.scratch))
        try repository.git("add", "-A")
        try repository.git("config", "project-hooks.trusted", "maybe")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(!repository.scratchExists("pre-commit-task-ran"))
        #expect(run.output.contains("Ignoring project-hooks.trusted"))
    }
}
