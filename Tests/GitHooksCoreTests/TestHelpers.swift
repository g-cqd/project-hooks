import Foundation

func makeTempDir(prefix: String = "hooks-test") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// This process's environment without the user's git configuration or any inherited `GIT_*` variable, with a fixed
/// commit identity.
let hermeticGitEnvironment: [String: String] = {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    for role in ["AUTHOR", "COMMITTER"] {
        environment["GIT_\(role)_NAME"] = "Test"
        environment["GIT_\(role)_EMAIL"] = "test@example.com"
    }
    return environment
}()

/// Run git in `directory` with `hermeticGitEnvironment`, and fail the calling test if git fails.
func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.environment = hermeticGitEnvironment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitFailure(arguments: arguments, exitCode: process.terminationStatus)
    }
}

struct GitFailure: Error {
    let arguments: [String]
    let exitCode: Int32
}
