import ArgumentParser
import Darwin
import Foundation
import GitHooksCore

struct CommandResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var stdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrText: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    var combinedText: String {
        stdoutText + stderrText
    }
}

enum HookError: Error {
    case message(String)
}

private let preferredBinPaths = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
]

func mergedEnvironment(_ overrides: [String: String]? = nil) -> [String: String] {
    var env = ProcessInfo.processInfo.environment

    let currentPath = env["PATH"] ?? ""
    var pathEntries = currentPath.split(separator: ":").map(String.init)

    for preferredPath in preferredBinPaths.reversed() where !pathEntries.contains(preferredPath) {
        pathEntries.insert(preferredPath, at: 0)
    }

    // Auto-discover JDK so gradle/xcodebuild subprocesses don't trip over macOS's
    // `/usr/bin/java` stub when the user hasn't exported JAVA_HOME themselves.
    if let javaHome = EnvDiscovery.discoverJavaHome(currentEnv: env) {
        env["JAVA_HOME"] = javaHome
        let javaBin = "\(javaHome)/bin"
        if !pathEntries.contains(javaBin) {
            pathEntries.insert(javaBin, at: 0)
        }
    }

    // Auto-discover Android SDK for gradle android-plugin subprocesses.
    if let androidSdk = EnvDiscovery.discoverAndroidSdk(currentEnv: env) {
        env["ANDROID_HOME"] = androidSdk
        env["ANDROID_SDK_ROOT"] = androidSdk
    }

    env["PATH"] = pathEntries.joined(separator: ":")

    if let overrides {
        for (key, value) in overrides {
            env[key] = value
        }
    }

    return env
}

func timeoutFromEnv(_ key: String, defaultSeconds: TimeInterval) -> TimeInterval {
    if let value = ProcessInfo.processInfo.environment[key], let parsed = TimeInterval(value), parsed > 0 {
        return parsed
    }

    return defaultSeconds
}

private func childProcessIDs(of parentID: pid_t) -> [pid_t] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-P", String(parentID)]
    process.standardInput = FileHandle.nullDevice

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return []
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return
        output
        .split(whereSeparator: \.isNewline)
        .compactMap { pid_t(String($0)) }
}

private func descendantProcessIDs(of parentID: pid_t) -> [pid_t] {
    var seen: Set<pid_t> = [parentID]
    var pending = [parentID]
    var descendants: [pid_t] = []

    while let current = pending.popLast() {
        for childID in childProcessIDs(of: current) where seen.insert(childID).inserted {
            descendants.append(childID)
            pending.append(childID)
        }
    }

    return descendants
}

private func isProcessRunning(_ processID: pid_t) -> Bool {
    errno = 0
    return kill(processID, 0) == 0 || errno == EPERM
}

private func signalProcessIDs(_ processIDs: [pid_t], signal: Int32) {
    for processID in processIDs where processID > 0 {
        _ = kill(processID, signal)
    }
}

/// Wait for a process to finish, enforcing a deadline.
///
/// Returns true if the process timed out.
/// Attempts graceful termination before force-killing.
private func waitForProcess(_ process: Process, deadline: Date) -> Bool {
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
    }

    guard process.isRunning else {
        process.waitUntilExit()
        return false
    }

    let processTree = descendantProcessIDs(of: process.processIdentifier).reversed() + [process.processIdentifier]

    signalProcessIDs(processTree, signal: SIGTERM)
    Thread.sleep(forTimeInterval: 1.0)
    if process.isRunning || processTree.contains(where: isProcessRunning) {
        signalProcessIDs(processTree, signal: SIGINT)
        Thread.sleep(forTimeInterval: 0.5)
    }

    if process.isRunning || processTree.contains(where: isProcessRunning) {
        signalProcessIDs(processTree, signal: SIGKILL)
    }

    process.waitUntilExit()
    return true
}

/// Run a command and capture output.
///
/// On timeout, the process is killed and partial output is returned
/// in the `CommandResult` with `timedOut = true` (instead of throwing).
@discardableResult
func runCommand(
    _ args: [String],
    currentDirectory: String? = nil,
    environment: [String: String]? = nil,
    timeoutSeconds: TimeInterval? = nil,
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.environment = mergedEnvironment(environment)
    // Prevent processes (xcodebuild, gradle) from blocking on stdin reads
    process.standardInput = FileHandle.nullDevice

    if let currentDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    }

    // Use temp files instead of Pipe to avoid pipe buffer deadlocks.
    // Pipes have a ~64KB buffer; if a process writes more, it blocks waiting for the reader,
    // while we're blocked on waitUntilExit() → deadlock. Temp files have no buffer limit.
    let tempDir = FileManager.default.temporaryDirectory
    let stdoutURL = tempDir.appendingPathComponent("project-hooks-stdout-\(UUID().uuidString).log")
    let stderrURL = tempDir.appendingPathComponent("project-hooks-stderr-\(UUID().uuidString).log")

    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    try process.run()

    let didTimeout: Bool
    if let timeoutSeconds {
        // Explicit timeout: poll with deadline
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        didTimeout = waitForProcess(process, deadline: deadline)
    } else {
        // No explicit timeout: block directly (no polling overhead for fast commands)
        // Safety net: 1-hour max to prevent infinite hangs
        let deadline = Date().addingTimeInterval(3600)
        didTimeout = waitForProcess(process, deadline: deadline)
    }

    try? stdoutHandle.close()
    try? stderrHandle.close()

    let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
    let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()

    return CommandResult(
        exitCode: didTimeout ? -1 : process.terminationStatus,
        stdout: stdoutData,
        stderr: stderrData,
        timedOut: didTimeout,
    )
}

func splitNullSeparated(_ data: Data) -> [String] {
    data
        .split(separator: 0)
        .compactMap { String(data: $0, encoding: .utf8) }
}

func printSection(_ text: String) {
    print("\n\(text)")
}

func printInfo(_ text: String) {
    print("[INFO] \(text)")
}

func printWarn(_ text: String) {
    print("[WARN] \(text)")
}

func printError(_ text: String) {
    print("[ERROR] \(text)")
}

func printOK(_ text: String) {
    print("[OK] \(text)")
}

func gitRepoRoot() throws -> String {
    let result = try runCommand(["git", "rev-parse", "--show-toplevel"])
    guard result.exitCode == 0 else {
        throw HookError.message("Could not resolve repository root")
    }

    return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
}

func gitNullSeparated(_ args: [String], repoRoot: String, allowFailure: Bool = false) throws -> [String] {
    let result = try runCommand(["git"] + args, currentDirectory: repoRoot)
    guard result.exitCode == 0 else {
        if allowFailure {
            return []
        }

        let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw HookError.message("git \(args.joined(separator: " ")) failed: \(stderr)")
    }
    return splitNullSeparated(result.stdout)
}

func gitLines(_ args: [String], repoRoot: String, allowFailure: Bool = false) throws -> [String] {
    let result = try runCommand(["git"] + args, currentDirectory: repoRoot)
    guard result.exitCode == 0 else {
        if allowFailure {
            return []
        }

        let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw HookError.message("git \(args.joined(separator: " ")) failed: \(stderr)")
    }

    return result.stdoutText
        .split(whereSeparator: \.isNewline)
        .map { String($0) }
        .filter { !$0.isEmpty }
}

func gitFirstLine(_ args: [String], repoRoot: String, allowFailure: Bool = false) throws -> String? {
    try gitLines(args, repoRoot: repoRoot, allowFailure: allowFailure).first
}

// MARK: - Staged file collection

func collectStagedFiles(repoRoot: String) throws -> [String] {
    let result = try runCommand(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
        currentDirectory: repoRoot,
    )
    guard result.exitCode == 0 else {
        throw HookError.message("Failed to collect staged files")
    }
    return splitNullSeparated(result.stdout)
}

// MARK: - Custom task execution

func runCustomTasks(
    _ tasks: [HooksConfig.CustomTask],
    files: [String],
    repoRoot: String,
    blockMessage: String,
) throws {
    guard !tasks.isEmpty else { return }

    guard let ordered = TaskDependencyResolver.resolve(tasks) else {
        throw HookError.message("Circular dependency in custom tasks")
    }

    var skippedTasks = Set<String>()

    for task in ordered {
        // Skip if dependency was skipped
        if let dep = task.after, skippedTasks.contains(dep) {
            printOK("\(task.name) skipped (dependency \"\(dep)\" was skipped).")
            skippedTasks.insert(task.name)
            continue
        }

        // Filter by file patterns if configured
        var matchedFiles = files
        if let patterns = task.onFiles {
            matchedFiles = FileGlobMatcher.filter(files, matching: patterns)
            if matchedFiles.isEmpty {
                printOK("No matching files for \(task.name). Skipping.")
                skippedTasks.insert(task.name)
                continue
            }
            printInfo("\(task.name): \(matchedFiles.count) matching file(s)")
        }

        printSection(task.name)
        let timeout = TimeInterval(task.timeout ?? 120)

        let result = try runCommand(
            ["/bin/bash", "-c", task.run],
            currentDirectory: repoRoot,
            timeoutSeconds: timeout,
        )

        if result.timedOut {
            printError("\(task.name) timed out after \(Int(timeout))s.")
            throw ExitCode(1)
        }

        if !result.combinedText.isEmpty {
            print(result.combinedText, terminator: "")
        }

        guard result.exitCode == 0 else {
            printError("\(task.name) failed.")
            printWarn("\(blockMessage) blocked. Fix issues and try again.")
            throw ExitCode(1)
        }

        printOK("\(task.name) completed.")

        // Re-stage files if configured — uses the matched subset, not all staged files
        if let restage = task.restage {
            try restageFiles(restage, matchedFiles: matchedFiles, repoRoot: repoRoot)
        }
    }
}

private func restageFiles(
    _ config: HooksConfig.RestageConfig,
    matchedFiles: [String],
    repoRoot: String,
) throws {
    let filesToStage: [[String]] =
        switch config {
            case .matchedFiles:
                matchedFiles.isEmpty ? [] : [matchedFiles]
            case .paths(let paths):
                paths.map { [$0] }
        }

    for batch in filesToStage {
        let result = try runCommand(["git", "add", "--"] + batch, currentDirectory: repoRoot)
        guard result.exitCode == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("Failed to restage files: \(stderr)")
        }
    }
}
