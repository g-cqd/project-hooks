import Foundation
import GitHooksCore

/// A unique scratch directory under `/tmp/project-hooks-build/` owning the lifecycle of one
/// Swift / xcodebuild invocation's intermediates.
///
/// Mitigates state leaking between hook invocations and transient races in shared DerivedData
/// / SPM `.build` (e.g. Swift driver JSON IPC corruption surfacing as `Internal Error:
/// DecodingError.dataCorrupted ... unexpected end of file`). The pure command-shaping logic
/// lives in `BuildIsolation` in `GitHooksCore` so it stays unit-testable.
struct IsolatedScratch {
    let path: String

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-hooks-build")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Run a Swift / xcodebuild test or build command inside an isolated `/tmp` scratch directory.
///
/// Each invocation gets its own DerivedData / SPM `.build` so concurrent hook runs (and any
/// Xcode session running alongside) can't trample shared state. The scratch directory is
/// removed when the run completes regardless of outcome. Non-isolated tools (gradle, others)
/// pass through to `runCommand` with their original arguments.
@discardableResult
func runIsolatedBuildCommand(
    _ args: [String],
    currentDirectory: String? = nil,
    environment: [String: String]? = nil,
    timeoutSeconds: TimeInterval? = nil,
) throws -> CommandResult {
    let scratch = try IsolatedScratch()
    defer { scratch.cleanup() }

    let isolated = BuildIsolation.inject(into: args, scratchPath: scratch.path)
    return try runCommand(
        isolated,
        currentDirectory: currentDirectory,
        environment: environment,
        timeoutSeconds: timeoutSeconds,
    )
}
