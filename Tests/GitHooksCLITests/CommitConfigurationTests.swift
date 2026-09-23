import Foundation
import Testing

/// From the review of the PH-5 fix: tasks and tests run on the pushed commit, so they must follow that commit's
/// `.project-hooks.yml`, not the checked-out branch's.
struct CommitConfigurationTests {
    @Test
    func `a pushed branch runs its own tasks, not the checked-out branch's`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", taskConfig(marker: "main-task-ran", in: repository))
        try repository.write("notes.txt", "main\n")
        try repository.commitAll("Add main's task")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.write(".project-hooks.yml", taskConfig(marker: "feature-task-ran", in: repository))
        try repository.write("notes.txt", "feature\n")
        let feature = try repository.commitAll("Add feature's task")
        try repository.git("checkout", "-q", "main")
        try repository.trust()

        let push = try repository.runPrePush(branch: "feature", localSHA: feature)

        #expect(push.exitCode == 0, "\(push.output)")
        #expect(repository.scratchExists("feature-task-ran"))
        #expect(!repository.scratchExists("main-task-ran"))
    }

    @Test
    func `a commit without a configuration runs no repository task`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.git("rm", "-q", ".project-hooks.yml")
        try repository.write("notes.txt", "notes\n")
        let head = try repository.commitAll("Remove the configuration")
        // Only in the working tree, and not in the pushed commit.
        try repository.write(".project-hooks.yml", taskConfig(marker: "working-tree-task-ran", in: repository))
        try repository.trust()

        let push = try repository.runPrePush(localSHA: head)

        #expect(push.exitCode == 0, "\(push.output)")
        #expect(!repository.scratchExists("working-tree-task-ran"))
    }

    private func taskConfig(marker: String, in repository: ScratchRepository) -> String {
        "pre-push:\n  tasks:\n    - name: \"Mark\"\n      run: \"touch '\(repository.scratch.appendingPathComponent(marker).path)'\"\n"
    }
}
