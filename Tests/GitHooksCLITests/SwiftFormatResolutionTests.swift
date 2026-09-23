import Foundation
import Testing

/// Review finding PH-2: which swift-format ran depended on `PATH` order, so a terminal and a git client launched from
/// the Dock could reach different verdicts on the same staged files.
struct SwiftFormatResolutionTests {
    /// Whether Xcode's toolchain provides swift-format on this machine.
    static let xcodeHasSwiftFormat: Bool = {
        let run = try? runProcess(
            ["/usr/bin/xcrun", "--find", "swift-format"],
            in: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
        )
        return run?.exitCode == 0
    }()

    @Test(.enabled(if: xcodeHasSwiftFormat))
    func `swift-format on PATH is not used`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        for tool in ["swift-format", "swift"] {
            try repository.installTool(
                tool,
                script: "#!/bin/sh\ntouch '\(repository.scratch.path)/\(tool)-from-path-ran'\n",
            )
        }

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(
            !FileManager.default
                .fileExists(atPath: repository.scratch.appendingPathComponent("swift-format-from-path-ran").path))
        #expect(
            !FileManager.default
                .fileExists(atPath: repository.scratch.appendingPathComponent("swift-from-path-ran").path))
        #expect(run.output.contains("swift-format: /"), "the hook reports which binary it ran")
    }

    @Test(.enabled(if: xcodeHasSwiftFormat))
    func `a .swift-version that names a missing toolchain falls back to Xcode and says why`() throws {
        let repository = try makeRepository()
        defer { repository.remove() }
        try repository.write(".swift-version", "5.0.0-missing\n")
        try repository.git("add", "-A")

        let run = try repository.runProjectHooks(["pre-commit"])

        #expect(run.exitCode == 0, "\(run.output)")
        #expect(run.output.contains("Xcode toolchain, via xcrun; .swift-version names 5.0.0-missing"), "\(run.output)")
    }

    /// A repository with a swift-format configuration and a staged, correctly formatted Swift file.
    private func makeRepository(name: String = #function) throws -> ScratchRepository {
        let repository = try ScratchRepository.make(name)
        try repository.write("Package.swift", "// swift-tools-version: 6.0\n")
        try repository.write(".swift-format", "{ \"version\": 1 }\n")
        try repository.write("Sources/App.swift", "let value = 1\n")
        try repository.git("add", "-A")
        return repository
    }
}
