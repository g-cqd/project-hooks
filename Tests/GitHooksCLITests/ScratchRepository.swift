import Foundation

/// A throwaway git repository for end-to-end tests of the `project-hooks` binary.
///
/// Git runs with no user or system configuration and a fixed identity. The binary gets its own cache directory, and a
/// directory for fake tools comes first on its `PATH`. The repository starts with an empty `.project-hooks.yml`, so the
/// user's own configuration never applies.
struct ScratchRepository {
    /// The directory that holds the repository and everything else the test creates.
    let scratch: URL
    /// The repository's working tree.
    let root: URL

    var path: String {
        root.path
    }

    var fakeTools: URL {
        scratch.appendingPathComponent("bin")
    }

    var cacheDirectory: URL {
        scratch.appendingPathComponent("cache")
    }

    /// The environment for git and for the binary.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("GIT_") && !$0.key.hasPrefix("GITHOOKS_")
        }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        for role in ["AUTHOR", "COMMITTER"] {
            environment["GIT_\(role)_NAME"] = "Test"
            environment["GIT_\(role)_EMAIL"] = "test@example.com"
        }
        environment["GITHOOKS_CACHE_DIR"] = cacheDirectory.path
        environment["PATH"] = ([fakeTools.path] + Self.systemPath).joined(separator: ":")
        return environment
    }

    private static let systemPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin",
        "/usr/sbin", "/sbin",
    ]

    /// Create a repository on branch `main`, with one commit that adds an empty `.project-hooks.yml`.
    static func make(_ name: String = #function) throws -> ScratchRepository {
        let label = name.filter { $0.isLetter || $0.isNumber }.prefix(40)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-hooks-e2e-\(label)-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        let repository = ScratchRepository(scratch: scratch, root: scratch.appendingPathComponent("repo"))
        try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.fakeTools, withIntermediateDirectories: true)
        try repository.git("init", "-q", "-b", "main")
        try repository.write(".project-hooks.yml", "")
        try repository.commitAll("Initial commit")
        return repository
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func write(_ relativePath: String, _ contents: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    /// Install an executable script called `name` in the fake tools directory.
    func installTool(_ name: String, script: String) throws {
        let url = fakeTools.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Run git in the repository and return its standard output.
    ///
    /// Throws when git fails.
    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let run = try runProcess(["git"] + arguments, in: root, environment: environment)
        guard run.exitCode == 0 else {
            throw ScratchFailure.command(["git"] + arguments, run.output)
        }
        return run.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stage everything and commit it.
    ///
    /// Returns the new commit's hash.
    @discardableResult
    func commitAll(_ message: String) throws -> String {
        try git("add", "-A")
        try git("commit", "-q", "--no-verify", "-m", message)
        return try git("rev-parse", "HEAD")
    }

    func trust() throws {
        try git("config", "project-hooks.trusted", "true")
    }

    /// Run the binary in the repository, with `stdin` as its standard input.
    func runProjectHooks(_ arguments: [String], stdin: String? = nil) throws -> ProcessRun {
        try runProcess([ProjectHooksBinary.path] + arguments, in: root, environment: environment, stdin: stdin)
    }

    /// Run the pre-push hook for pushing `localSHA` as a new `refs/heads/<branch>` on `origin`.
    func runPrePush(branch: String = "main", localSHA: String, remoteSHA: String = Self.zeroSHA) throws -> ProcessRun {
        try runProjectHooks(
            ["pre-push", "origin", "unused-url"],
            stdin: "refs/heads/\(branch) \(localSHA) refs/heads/\(branch) \(remoteSHA)\n",
        )
    }

    static let zeroSHA = String(repeating: "0", count: 40)
}

struct ProcessRun {
    let exitCode: Int32
    /// Standard output and standard error, interleaved.
    let output: String
}

enum ScratchFailure: Error {
    case command([String], String)
}

/// The `project-hooks` binary under test: `PROJECT_HOOKS_TEST_BINARY` if set, otherwise the build next to this bundle.
enum ProjectHooksBinary {
    static let path: String =
        ProcessInfo.processInfo.environment["PROJECT_HOOKS_TEST_BINARY"]
        ?? Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("project-hooks").path

    private final class BundleLocator {}
}

/// Run a command and wait for it.
///
/// Output goes to a file, so a large output cannot block the child.
func runProcess(
    _ command: [String],
    in directory: URL,
    environment: [String: String],
    stdin: String? = nil,
) throws -> ProcessRun {
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardOutput = output
    process.standardError = output

    let input = Pipe()
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
    try process.run()
    if let stdin {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
    }
    process.waitUntilExit()

    let text = try String(contentsOf: outputURL, encoding: .utf8)
    return ProcessRun(exitCode: process.terminationStatus, output: text)
}
