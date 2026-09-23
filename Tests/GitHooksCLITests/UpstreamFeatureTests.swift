import Foundation
import Testing

/// Pre-push now checks each pushed commit on its own.
///
/// These pin the checks that still run once per push, from the working tree's configuration: commit messages with
/// `base`, the PR size, and a skipped test stage.
struct UpstreamFeatureTests {
    private static let commitMessageRule = """
        pre-push:
          commit-message:
            pattern: "^FEAT-[0-9]+ "
            error: "Start the message with the ticket"

        """

    @Test
    func `commit-message base keeps inherited commits out of validation`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write("legacy.txt", "legacy\n")
        try repository.commitAll("legacy change")
        try repository.git("branch", "develop")
        try repository.git("checkout", "-q", "-b", "feature/FEAT-1")
        try repository.write("feature.txt", "feature\n")
        let head = try repository.commitAll("FEAT-1 add the feature")

        try repository.write(".project-hooks.yml", Self.commitMessageRule)
        let withoutBase = try repository.runPrePush(branch: "feature/FEAT-1", localSHA: head)
        try repository.write(".project-hooks.yml", Self.commitMessageRule + "    base: \"develop\"\n")
        let withBase = try repository.runPrePush(branch: "feature/FEAT-1", localSHA: head)

        #expect(withoutBase.exitCode == 1, "\(withoutBase.output)")
        #expect(withoutBase.output.contains("legacy change"))
        #expect(withBase.exitCode == 0, "\(withBase.output)")
        #expect(withBase.output.contains("excluding commits reachable from 'develop'"))
    }

    @Test
    func `the PR-size check blocks an oversized push`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        try repository.write(".project-hooks.yml", "pre-push:\n  pr-size:\n    mode: fail\n    max-files: 1\n")
        let base = try repository.commitAll("Limit the PR size")
        for name in ["one", "two", "three"] {
            try repository.write("Sources/\(name).txt", "\(name)\n")
        }
        let head = try repository.commitAll("Add three files")

        let run = try repository.runPrePush(localSHA: head, remoteSHA: base)

        #expect(run.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("PR size check"))
        #expect(run.output.contains("Push blocked. Split the change"))
    }

    @Test
    func `a skipped test override runs nothing in a trusted repository`() throws {
        let repository = try ScratchRepository.make()
        defer { repository.remove() }
        let marker = repository.scratch.appendingPathComponent("gradle-ran").path
        try repository.write(".project-hooks.yml", "pre-push:\n  test-override:\n    type: gradle\n    skip: true\n")
        try repository.write("gradlew", "#!/bin/sh\ntouch '\(marker)'\n", executable: true)
        let head = try repository.commitAll("Skip the tests")
        try repository.trust()

        let run = try repository.runPrePush(localSHA: head)

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(run.output.contains("test-override.skip: true"))
        #expect(!repository.scratchExists("gradle-ran"))
    }
}
