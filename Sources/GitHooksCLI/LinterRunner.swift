import ArgumentParser
import Foundation
import GitHooksCore

let defaultLinterFallbackPaths: [String: String] = [
    "swiftlint": "BuildTools/.build/release/swiftlint",
    "swiftformat": "BuildTools/.build/release/swiftformat",
]

// MARK: - Linter invocation builder

private struct LinterInvocation {
    let args: [String]
    let env: [String: String]?
}

private func swiftLintInvocation(_ linter: DiscoveredLinter, files: [String], config: String?) -> LinterInvocation {
    var env = ProcessInfo.processInfo.environment
    env["SCRIPT_INPUT_FILE_COUNT"] = String(files.count)
    for (index, file) in files.enumerated() {
        env["SCRIPT_INPUT_FILE_\(index)"] = file
    }
    if let config { env["SWIFTLINT_CONFIG_FILE"] = config }
    var args = [linter.executablePath, "lint", "--strict", "--use-script-input-files"]
    if let config { args += ["--config", config] }
    return LinterInvocation(args: args, env: env)
}

private func swiftFormatInvocation(_ linter: DiscoveredLinter, files: [String], config: String?) -> LinterInvocation {
    // SwiftFormat resolves paths relative to currentDirectory, so pass relative paths
    var args = [linter.executablePath, "--lint"]
    if let config { args += ["--config", config] }
    return LinterInvocation(args: args + files, env: nil)
}

private func swiftFormatOfficialInvocation(
    _ linter: DiscoveredLinter,
    files: [String],
    config: String?,
) -> LinterInvocation {
    var args: [String] =
        if linter.usesSwiftSubcommand {
            [linter.executablePath, "format", "lint", "--strict"]
        } else {
            [linter.executablePath, "lint", "--strict"]
        }
    if let config { args += ["--configuration", config] }
    return LinterInvocation(args: args + files, env: nil)
}

private func detektInvocation(_ linter: DiscoveredLinter, files: [String], config: String?) -> LinterInvocation {
    var args = [linter.executablePath, "--input", files.joined(separator: ",")]
    if let config { args += ["--config", config] }
    return LinterInvocation(args: args, env: nil)
}

private func buildLinterInvocation(
    linter: DiscoveredLinter,
    absoluteFiles: [String],
    relativeFiles: [String],
    config: String?,
) -> LinterInvocation? {
    switch linter.name {
        case "SwiftLint":
            swiftLintInvocation(linter, files: absoluteFiles, config: config)
        case "SwiftFormat":
            swiftFormatInvocation(linter, files: relativeFiles, config: config)
        case "swift-format":
            swiftFormatOfficialInvocation(linter, files: absoluteFiles, config: config)
        case "ktlint":
            LinterInvocation(args: [linter.executablePath] + absoluteFiles, env: nil)
        case "detekt":
            detektInvocation(linter, files: absoluteFiles, config: config)
        default:
            nil
    }
}

private func printLinterTimeout(_ linter: DiscoveredLinter, timeout: TimeInterval, output: String) {
    printError("\(linter.name) timed out after \(Int(timeout))s.")
    printWarn("This may indicate a hung linter process. Try increasing the timeout:")
    printWarn("  export GITHOOKS_\(linter.name.uppercased())_TIMEOUT_SECONDS=<seconds>")
    guard !output.isEmpty else { return }
    let lastLines = output.split(whereSeparator: \.isNewline).suffix(20)
    printInfo("Last output before timeout:")
    for line in lastLines {
        print("  \(line)")
    }
}

// MARK: - Shared linter runner

/// Run a discovered linter against a set of files with an optional config.
///
/// Returns the process exit code.
func runLinterCommand(
    linter: DiscoveredLinter,
    files: [String],
    config: String?,
    repoRoot: String,
    timeout: TimeInterval,
) throws -> Int32 {
    let absoluteFiles = files.map { "\(repoRoot)/\($0)" }

    guard
        let invocation = buildLinterInvocation(
            linter: linter,
            absoluteFiles: absoluteFiles,
            relativeFiles: files,
            config: config,
        )
    else {
        printWarn("Unknown linter \(linter.name), skipping.")
        return 0
    }

    let result = try runCommand(
        invocation.args,
        currentDirectory: repoRoot,
        environment: invocation.env,
        timeoutSeconds: timeout,
    )

    if result.timedOut {
        printLinterTimeout(linter, timeout: timeout, output: result.combinedText)
        return -1
    }

    if !result.combinedText.isEmpty {
        print(result.combinedText, terminator: "")
    }
    return result.exitCode
}

// MARK: - Grouped linter execution

/// Check whether a linter has at least one config file anywhere within the repo root.
private func linterHasConfig(_ linter: DiscoveredLinter, repoRoot: String) -> Bool {
    let fm = FileManager.default
    for candidate in linter.configCandidates {
        let path = URL(fileURLWithPath: repoRoot).appendingPathComponent(candidate).path
        if fm.fileExists(atPath: path) { return true }
    }
    return false
}

/// Run a linter against files grouped by their closest config file.
///
/// Used by both pre-commit and pre-push commands.
func runLinterGrouped(
    _ linter: DiscoveredLinter,
    files: [String],
    repoRoot: String,
    blockMessage: String,
) throws {
    if linter.requiresConfig, !linterHasConfig(linter, repoRoot: repoRoot) {
        printOK("No config found for \(linter.name). Skipping.")
        return
    }

    let relevantFiles = LinterDiscovery.filterFiles(files, forPlatform: linter.platform)

    guard !relevantFiles.isEmpty else {
        printOK("No \(linter.platform.rawValue) files to lint. Skipping \(linter.name).")
        return
    }

    let envKey = "GITHOOKS_\(linter.name.uppercased().replacingOccurrences(of: "-", with: "_"))_TIMEOUT_SECONDS"
    let timeout = timeoutFromEnv(envKey, defaultSeconds: 120)

    let groups = ConfigResolver.groupFilesByConfig(
        files: relevantFiles,
        repoRoot: repoRoot,
        candidates: linter.configCandidates,
    )

    for group in groups {
        // Show config path relative to repo root for clarity
        let configLabel =
            group.config.map { configPath in
                if configPath.hasPrefix(repoRoot) {
                    return String(configPath.dropFirst(repoRoot.count + 1))
                }
                return configPath
            } ?? "no config"

        printSection("\(linter.name) (\(configLabel), \(group.files.count) file(s))")

        if let config = group.config {
            printInfo("Config: \(config)")
        }

        for file in group.files {
            print("  - \(file)")
        }

        let exitCode = try runLinterCommand(
            linter: linter,
            files: group.files,
            config: group.config,
            repoRoot: repoRoot,
            timeout: timeout,
        )

        guard exitCode == 0 else {
            printError("\(linter.name) reported violations.")
            printWarn("\(blockMessage) blocked. Fix issues and try again.")
            throw ExitCode(1)
        }

        printOK("\(linter.name) checks passed.")
    }
}
