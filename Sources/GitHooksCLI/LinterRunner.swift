import ArgumentParser
import Foundation
import GitHooksCore

/// Linters that a repository builds itself, by binary name, at paths relative to its root.
///
/// A binary that the repository builds is the repository's own code, so these paths are searched only in trusted
/// repositories.
let defaultLinterFallbackPaths: [String: String] = [
    "swiftlint": "BuildTools/.build/release/swiftlint",
    "swiftformat": "BuildTools/.build/release/swiftformat",
]

/// Discover the linters for `platform`, searching `defaultLinterFallbackPaths` only when the repository is trusted.
///
/// In an untrusted repository, report each linter build that was skipped because no installed linter replaces it.
func discoverLinters(platform: Platform, repoRoot: String, trusted: Bool) -> [DiscoveredLinter] {
    let linters = LinterDiscovery.discoverLinters(
        forPlatform: platform,
        repoRoot: repoRoot,
        fallbackPaths: trusted ? defaultLinterFallbackPaths : [:],
    )
    guard !trusted, platform == .ios || platform == .mixed else { return linters }

    let discoveredBinaries = Set(linters.map { URL(fileURLWithPath: $0.executablePath).lastPathComponent })
    let skippedBuilds = defaultLinterFallbackPaths.filter { binary, relativePath in
        let path = URL(fileURLWithPath: repoRoot).appendingPathComponent(relativePath).path
        return !discoveredBinaries.contains(binary) && FileManager.default.isExecutableFile(atPath: path)
    }
    for (binary, relativePath) in skippedBuilds.sorted(by: { $0.key < $1.key }) {
        RepositoryTrust.reportSkipped("the repository's own \(binary) at \(relativePath)")
    }
    return linters
}

// MARK: - Linter invocation builder

private struct LinterInvocation {
    let args: [String]
    let env: [String: String]?
}

private func swiftLintInvocation(_ linter: DiscoveredLinter, files: [String], config: String?) -> LinterInvocation {
    // Only the variables that SwiftLint reads: `runCommand` applies them on top of the computed environment.
    var env: [String: String] = [:]
    env["SCRIPT_INPUT_FILE_COUNT"] = String(files.count)
    for (index, file) in files.enumerated() {
        env["SCRIPT_INPUT_FILE_\(index)"] = file
    }
    if let config { env["SWIFTLINT_CONFIG_FILE"] = config }
    // Without `--force-exclude`, SwiftLint lints input files that its configuration excludes.
    var args = [linter.executablePath, "lint", "--strict", "--force-exclude", "--use-script-input-files"]
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

/// Run a discovered linter against a set of files with an optional config, and print its output.
/// - Parameters:
///   - linter: The linter to run.
///   - files: Paths relative to `workspace.root`.
///   - config: The configuration file that covers the files, if any.
///   - workspace: Where the files are, and which paths the output names instead.
///   - timeout: How long the linter may run.
/// - Returns: How the run ended.
/// - Throws: When the linter cannot start.
func runLinterCommand(
    linter: DiscoveredLinter,
    files: [String],
    config: String?,
    workspace: LintWorkspace,
    timeout: TimeInterval,
) throws -> LintOutcome {
    let absoluteFiles = files.map { "\(workspace.root)/\($0)" }

    guard
        let invocation = buildLinterInvocation(
            linter: linter,
            absoluteFiles: absoluteFiles,
            relativeFiles: files,
            config: config,
        )
    else {
        printWarn("Unknown linter \(linter.name), skipping.")
        return .passed
    }

    let result = try runCommand(
        invocation.args,
        currentDirectory: workspace.root,
        environment: invocation.env,
        timeoutSeconds: timeout,
    )
    let output = workspace.repositoryPaths(in: result.combinedText)

    if result.timedOut {
        printLinterTimeout(linter, timeout: timeout, output: output)
        return .timedOut
    }

    if !output.isEmpty {
        print(output, terminator: "")
    }
    return LintOutcome.classify(linterName: linter.name, exitCode: result.exitCode, output: output)
}

/// The linter's binary, where it came from, and, for swift-format, whose verdict depends on the toolchain, its version.
private func describe(_ linter: DiscoveredLinter) -> String {
    var description = "\(linter.name): \(linter.executablePath)"
    if linter.name == "swift-format",
        let result = try? runCommand([linter.executablePath, "--version"], timeoutSeconds: 10),
        result.exitCode == 0
    {
        description += " (version \(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }
    if let origin = linter.origin {
        description += ", \(origin)"
    }
    return description
}

// MARK: - Grouped linter execution

/// Run a linter against files grouped by their closest config file, and report every group's outcome.
///
/// Used by both pre-commit and pre-push commands.
/// - Parameters:
///   - linter: The linter to run.
///   - files: Repository-relative paths. The linter reads them, and their configuration, from `workspace.root`.
///   - workspace: Where the linter reads the files, and which paths its output names instead.
///   - ledger: Files that passed before with the same content and configuration are skipped, and files that pass are
///     recorded.
/// - Returns: A label for each group that did not pass, empty when all passed.
/// - Throws: When a linter cannot start.
func runLinterGrouped(
    _ linter: DiscoveredLinter,
    files: [String],
    workspace: LintWorkspace,
    ledger: LintLedger,
) throws -> [String] {
    let relevantFiles = LinterDiscovery.filterFiles(files, forPlatform: linter.platform)

    guard !relevantFiles.isEmpty else {
        printOK("No \(linter.platform.rawValue) files to lint. Skipping \(linter.name).")
        return []
    }

    // A linter that requires a configuration lints each file that a configuration covers, wherever that
    // configuration is, and skips the others.
    let allGroups = ConfigResolver.groupFilesByConfig(
        files: relevantFiles,
        repoRoot: workspace.root,
        candidates: linter.configCandidates,
    )
    let groups = linter.requiresConfig ? allGroups.filter { $0.config != nil } : allGroups
    let uncovered = relevantFiles.count - groups.reduce(0) { $0 + $1.files.count }
    if uncovered > 0 {
        printOK("No \(linter.name) config covers \(uncovered) file(s). Skipping them.")
    }
    guard !groups.isEmpty else { return [] }

    printInfo(describe(linter))

    let envKey = "GITHOOKS_\(linter.name.uppercased().replacingOccurrences(of: "-", with: "_"))_TIMEOUT_SECONDS"
    let timeout = timeoutFromEnv(envKey, defaultSeconds: 120)
    let identity = LintLedger.identity(of: linter)
    var failures: [String] = []

    for group in groups {
        // Show config path relative to repo root for clarity
        let configLabel =
            group.config.map { configPath in
                if configPath.hasPrefix(workspace.root) {
                    return String(configPath.dropFirst(workspace.root.count + 1))
                }
                return configPath
            } ?? "no config"

        printSection("\(linter.name) (\(configLabel), \(group.files.count) file(s))")

        if let config = group.config {
            printInfo("Config: \(workspace.repositoryPaths(in: config))")
        }

        let keys = group.files
            .map { ledger.key(for: $0, linter: linter, linterIdentity: identity, workspace: workspace) }
        let pending = zip(group.files, keys).filter { _, key in key.map { !ledger.store.hasPassed($0) } ?? true }
        if pending.count < group.files.count {
            printOK(
                "\(group.files.count - pending.count) file(s) passed \(linter.name) before, "
                    + "with the same content and configuration. Skipping them.")
        }
        guard !pending.isEmpty else { continue }

        for (file, _) in pending {
            print("  - \(file)")
        }

        // Some linters take one argument per file, and a command cannot have more than 4096.
        var groupPassed = true
        for chunk in pending.chunked(into: maxArgumentsPerCommand) {
            let outcome = try runLinterCommand(
                linter: linter,
                files: chunk.map(\.0),
                config: group.config,
                workspace: workspace,
                timeout: timeout,
            )

            switch outcome {
                case .passed:
                    printOK("\(linter.name) checks passed.")
                case .allFilesExcluded:
                    printOK("\(linter.name) configuration excludes these files. Nothing to lint.")
                case .violations:
                    printError("\(linter.name) reported violations.")
                case .failed(let exitCode):
                    printError("\(linter.name) failed to run (exit \(exitCode)). Its output is above.")
                case .timedOut:
                    break
            }

            if outcome.passes {
                ledger.store.recordPasses(chunk.compactMap(\.1))
            } else {
                groupPassed = false
            }
        }
        if !groupPassed {
            failures.append("\(linter.name) (\(configLabel))")
        }
    }

    return failures
}

/// Block the commit or push when any linter group failed, naming each one.
func blockOnLintFailures(_ failures: [String], blockMessage: String) throws {
    guard !failures.isEmpty else { return }
    printSection("Lint results")
    printError("\(failures.count) lint group(s) did not pass:")
    for failure in failures {
        print("  - \(failure)")
    }
    printWarn("\(blockMessage) blocked. Fix issues and try again.")
    throw ExitCode(1)
}
