import ArgumentParser
import Foundation
import GitHooksCore

struct PrePushCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pre-push",
        abstract: "Run pre-push checks (auto-detects platform: lint + test + build)",
    )

    @Argument(help: "The name of the remote being pushed to.")
    var remoteName = "origin"

    @Argument(help: "The URL of the remote being pushed to.")
    var remoteURL = "unknown"

    mutating func run() throws {
        let repoRoot = try gitRepoRoot()
        let resolved = try HooksConfig.resolve(repoRoot: repoRoot)
        let config = resolved?.config
        let platform = ProjectDetector.detectPlatform(repoRoot: repoRoot)

        printSection("Pre-push checks")
        printInfo("Platform: \(platform.rawValue)")
        if let resolved { printInfo("Config: \(resolved.sourceDescription)") }
        printInfo("Remote: \(remoteName) (\(remoteURL))")

        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let stdin = String(data: stdinData, encoding: .utf8) ?? ""
        let updates = HookLogic.parsePushUpdates(from: stdin)

        // --- Step 1a: Branch-name validation (from config) ---
        try runBranchNameValidation(config: config, updates: updates)

        // --- Step 1b: Commit message validation (from config) ---
        try runCommitValidation(config: config, updates: updates, remoteName: remoteName, repoRoot: repoRoot)

        // --- Step 2: Collect changed files ---
        let changedFiles = try collectChangedFiles(
            config: config,
            updates: updates,
            remoteName: remoteName,
            repoRoot: repoRoot,
        )

        if changedFiles.isEmpty {
            printOK("No source changes detected. Skipping checks.")
            return
        }

        printInfo("Detected changed files: \(changedFiles.count)")
        for file in changedFiles {
            print("  - \(file)")
        }

        // --- Step 2c: PR size check (config-driven) ---
        try runPRSizeCheck(
            config: config,
            updates: updates,
            remoteName: remoteName,
            repoRoot: repoRoot,
        )

        // --- Step 3: Custom pre-push tasks ---
        try runCustomTasks(
            config?.prePush.tasks ?? [],
            files: changedFiles,
            repoRoot: repoRoot,
            blockMessage: "Push",
        )

        // --- Step 4: Lint ---
        let resolvedPlatform = resolveEffectivePlatform(changedFiles: changedFiles, detected: platform)
        try runLintChecks(changedFiles: changedFiles, platform: resolvedPlatform, repoRoot: repoRoot)

        // --- Step 5: Test + build ---
        try runTestChecks(
            config: config,
            changedFiles: changedFiles,
            platform: resolvedPlatform,
            repoRoot: repoRoot,
        )

        printOK("pre-push checks completed successfully.")
    }
}

// MARK: - Branch-name validation

private func runBranchNameValidation(config: HooksConfig?, updates: [GitPushUpdate]) throws {
    guard let branchConfig = config?.prePush.branchName else { return }

    printSection("Branch-name validation")

    var failures: [BranchNameValidator.Failure] = []
    var checked = 0

    for update in updates {
        if HookLogic.shouldSkipUpdate(update) { continue }
        // Only validate branch refs; ignore tag refs (already filtered by shouldSkipUpdate)
        // and other oddities like notes refs.
        guard update.localRef.hasPrefix("refs/heads/") else { continue }
        let branch = BranchNameValidator.shortBranchName(fromRef: update.localRef)
        checked += 1
        if let failure = BranchNameValidator.validate(branchName: branch, config: branchConfig) {
            failures.append(failure)
        }
    }

    if checked == 0 {
        printOK("No branch refs to validate.")
        return
    }

    if failures.isEmpty {
        printOK("Branch name(s) match the configured pattern.")
        return
    }

    for failure in failures {
        printError("Branch '\(failure.branch)': \(failure.reason)")
    }
    printWarn("Push blocked. Rename the branch (git branch -m) and push again.")
    throw ExitCode(1)
}

// MARK: - Commit validation

private func runCommitValidation(
    config: HooksConfig?,
    updates: [GitPushUpdate],
    remoteName: String,
    repoRoot: String,
) throws {
    let pushConfig = config?.prePush
    guard pushConfig?.commitMessage != nil || !(pushConfig?.rejectTrailers ?? []).isEmpty else {
        return
    }

    // Commit-message validation uses the *full* push range by default — a malformed commit
    // shouldn't sneak in just because work-scope filters it out for lint/test purposes.
    // When `commit-message.base` is configured, exclude commits reachable from that ref so
    // a rebased branch doesn't re-validate upstream commits it merely inherited.
    let excludeBase = try resolveCommitMessageExcludeBase(
        config: pushConfig?.commitMessage,
        repoRoot: repoRoot,
    )
    let commitSHAs = try collectCommitSHAs(
        updates: updates,
        remoteName: remoteName,
        repoRoot: repoRoot,
        excludeBase: excludeBase,
    )
    guard !commitSHAs.isEmpty else { return }

    printSection("Commit message validation")
    printInfo("Checking \(commitSHAs.count) commit(s)...")

    var commits: [(sha: String, message: String)] = []
    for sha in commitSHAs {
        let result = try runCommand(["git", "log", "-1", "--format=%B", sha], currentDirectory: repoRoot)
        guard result.exitCode == 0 else { continue }
        commits.append((sha: String(sha.prefix(10)), message: result.stdoutText))
    }

    let failures = CommitMessageValidator.validate(
        commits: commits,
        pattern: pushConfig?.commitMessage?.pattern,
        patternError: pushConfig?.commitMessage?.error,
        rejectTrailers: pushConfig?.rejectTrailers ?? [],
    )

    if failures.isEmpty {
        printOK("All commit messages are valid.")
        return
    }

    for failure in failures {
        printError("\(failure.sha) \(failure.title)")
        print("  -> \(failure.reason)")
    }

    printWarn("Push blocked. Fix commit messages (git rebase -i) and push again.")
    throw ExitCode(1)
}

// MARK: - Lint

private func resolveEffectivePlatform(changedFiles: [String], detected: Platform) -> Platform {
    let effective = ProjectDetector.detectPlatformFromFiles(changedFiles)
    return effective != .unknown ? effective : detected
}

private func runLintChecks(changedFiles: [String], platform: Platform, repoRoot: String) throws {
    let linters = LinterDiscovery.discoverLinters(
        forPlatform: platform,
        repoRoot: repoRoot,
        fallbackPaths: defaultLinterFallbackPaths,
    )

    guard !linters.isEmpty else {
        printWarn("No linters found. Skipping lint checks.")
        return
    }

    printInfo("Discovered linters: \(linters.map(\.name).joined(separator: ", "))")
    for linter in linters {
        try runLinterGrouped(linter, files: changedFiles, repoRoot: repoRoot, blockMessage: "Push")
    }
}

// MARK: - Test + build

private func runTestChecks(
    config: HooksConfig?,
    changedFiles: [String],
    platform: Platform,
    repoRoot: String,
) throws {
    // Config-driven test override
    if let override = config?.prePush.testOverride {
        try runTestOverride(override, changedFiles: changedFiles, repoRoot: repoRoot)
        return
    }

    // Auto-detected module testing
    let modules = TestTargetResolver.detectModules(
        changedFiles: changedFiles,
        repoRoot: repoRoot,
        platform: platform,
    )

    if modules.isEmpty {
        printOK("No test targets detected for changed files. Skipping tests.")
        return
    }

    try runModuleTests(modules: modules, repoRoot: repoRoot)

    let untestedModules = modules.filter(\.testCommand.isEmpty)
    if !untestedModules.isEmpty {
        try runModuleBuilds(modules: untestedModules, repoRoot: repoRoot)
    }
}

private func runTestOverride(_ override: HooksConfig.TestOverride, changedFiles: [String], repoRoot: String) throws {
    let testTimeout = timeoutFromEnv("GITHOOKS_TEST_TIMEOUT_SECONDS", defaultSeconds: 1200)

    guard var command = try buildOverrideCommand(override, changedFiles: changedFiles, repoRoot: repoRoot) else {
        return
    }

    if let extra = override.extraArgs, !extra.isEmpty {
        command.append(contentsOf: extra)
    }

    printSection("Tests (config override: \(override.type.rawValue))")
    printInfo("Command: \(command.joined(separator: " "))")
    printInfo("Timeout: \(Int(testTimeout))s")

    let result = try runCommand(command, currentDirectory: repoRoot, timeoutSeconds: testTimeout)
    diagnoseTestResult(result, moduleName: override.type.rawValue, timeout: testTimeout)

    if result.timedOut || result.exitCode != 0 {
        throw ExitCode(1)
    }
}

private func buildOverrideCommand(
    _ override: HooksConfig.TestOverride,
    changedFiles: [String],
    repoRoot: String,
) throws -> [String]? {
    let destination = ProcessInfo.processInfo.environment["GITHOOKS_DESTINATION"]
        ?? override.destination
        ?? "platform=iOS Simulator,name=iPhone 16"

    switch override.type {
    case .xcodebuild:
        return try buildXcodebuildOverride(
            override, changedFiles: changedFiles, repoRoot: repoRoot, destination: destination,
        )
    case .swift:
        return ["swift", "test", "--package-path", repoRoot]
    case .gradle:
        // Use gradlew from repo root directly — settings-only roots don't have build.gradle
        let gradlew = URL(fileURLWithPath: repoRoot).appendingPathComponent("gradlew").path
        let wrapper = FileManager.default.isExecutableFile(atPath: gradlew) ? gradlew : "gradle"
        let task = override.task?.trimmingCharacters(in: .whitespaces)
        return [wrapper, (task?.isEmpty == false ? task! : "test")]
    }
}

private func buildXcodebuildOverride(
    _ override: HooksConfig.TestOverride,
    changedFiles: [String],
    repoRoot: String,
    destination: String,
) throws -> [String]? {
    var command = ["xcodebuild", "test"]
    if let project = override.project { command += ["-project", project] }
    if let scheme = override.scheme { command += ["-scheme", scheme] }
    command += ["-destination", destination]

    guard let testPlan = override.testPlan else { return command }

    let resolution = HookLogic.resolveAvailableBundles(repoRoot: repoRoot, testPlanRelativePath: testPlan)
    if resolution.loadedFromXCTestPlan {
        printInfo("Loaded bundles from: \(resolution.xctestplanPath)")
    } else {
        throw HookError.message(
            "Could not load test plan: \(resolution.xctestplanPath). "
                + "Fix the test-plan path in .project-hooks.yml.",
        )
    }

    let broadPaths = override.broadImpactPaths ?? []
    let isBroadImpact = changedFiles.contains { file in
        broadPaths.contains { file.hasPrefix($0) || file == $0 }
    }

    if isBroadImpact {
        printWarn("Broad-impact files detected. Running all test bundles.")
        return command
    }

    let selected = HookLogic.selectBundles(changedFiles: changedFiles, availableBundles: resolution.bundles)
    if selected.isEmpty {
        printOK("No test bundles affected by changes. Skipping tests.")
        return nil
    }

    for bundle in selected {
        command.append("-only-testing:\(bundle)")
    }
    printInfo("Selected test bundles (\(selected.count)):")
    for bundle in selected {
        print("  - \(bundle)")
    }

    return command
}

// MARK: - Module-based test/build execution

private func runModuleTests(modules: [DetectedModule], repoRoot: String) throws {
    let testTimeout = timeoutFromEnv("GITHOOKS_TEST_TIMEOUT_SECONDS", defaultSeconds: 1200)

    for module in modules where !module.testCommand.isEmpty {
        printSection("Tests: \(module.name)")
        printInfo("Command: \(module.testCommand.joined(separator: " "))")
        printInfo("Timeout: \(Int(testTimeout))s")

        let result = try runCommand(module.testCommand, currentDirectory: repoRoot, timeoutSeconds: testTimeout)
        diagnoseTestResult(result, moduleName: module.name, timeout: testTimeout)

        if result.timedOut || result.exitCode != 0 {
            throw ExitCode(1)
        }
    }
}

private func runModuleBuilds(modules: [DetectedModule], repoRoot: String) throws {
    let buildTimeout = timeoutFromEnv("GITHOOKS_BUILD_TIMEOUT_SECONDS", defaultSeconds: 600)

    for module in modules where !module.buildCommand.isEmpty {
        printSection("Build: \(module.name)")
        printInfo("Command: \(module.buildCommand.joined(separator: " "))")

        let result = try runCommand(module.buildCommand, currentDirectory: repoRoot, timeoutSeconds: buildTimeout)

        if result.timedOut {
            printError("Build timed out after \(Int(buildTimeout))s for \(module.name).")
            throw ExitCode(1)
        }

        guard result.exitCode == 0 else {
            let errors = result.combinedText
                .split(whereSeparator: \.isNewline)
                .filter { $0.contains("error:") }
                .suffix(40)
            printError("Build failed for \(module.name).")
            for line in errors {
                print("  \(line)")
            }
            printWarn("Push blocked. Fix build errors and push again.")
            throw ExitCode(1)
        }

        printOK("Build succeeded for \(module.name).")
    }
}

// MARK: - Git helpers

private func collectCommitSHAs(
    updates: [GitPushUpdate],
    remoteName: String,
    repoRoot: String,
    excludeBase: String? = nil,
) throws -> [String] {
    var shas: [String] = []
    for update in updates {
        if update.isTagUpdate || update.isDeletion { continue }
        var args: [String] = if update.isNewRemoteRef {
            ["rev-list", update.localSHA, "--not", "--remotes=\(remoteName)"]
        } else {
            ["rev-list", "\(update.remoteSHA)..\(update.localSHA)"]
        }
        if let excludeBase {
            // For the new-ref form, `--not` is already in effect, so a positional ref is
            // added to the exclusion set. For the range form, prefix with `^` to exclude.
            args.append(update.isNewRemoteRef ? excludeBase : "^\(excludeBase)")
        }
        try shas.append(contentsOf: gitLines(args, repoRoot: repoRoot))
    }
    return shas
}

/// Resolve the `commit-message.base` ref to a SHA. Returns nil when the field is unset
/// or the ref cannot be resolved (a warning is printed in the latter case so the user
/// notices the misconfiguration without blocking the push).
private func resolveCommitMessageExcludeBase(
    config: HooksConfig.CommitMessageConfig?,
    repoRoot: String,
) throws -> String? {
    guard let base = config?.base, !base.isEmpty else { return nil }
    if let sha = try gitFirstLine(
        ["rev-parse", "--verify", "--quiet", base],
        repoRoot: repoRoot,
        allowFailure: true,
    ) {
        printInfo("commit-message: excluding commits reachable from '\(base)'.")
        return sha
    }
    printWarn("commit-message: base '\(base)' not found — validating full push range.")
    return nil
}

private func collectChangedFiles(
    config: HooksConfig?,
    updates: [GitPushUpdate],
    remoteName: String,
    repoRoot: String,
) throws -> [String] {
    var files = Set<String>()

    for update in updates {
        if HookLogic.shouldSkipUpdate(update) { continue }
        if let error = HookLogic.validateUpdateSHAs(update) {
            throw HookError.message(error)
        }

        // Try work-scope first. Returns nil when scope is disabled or doesn't apply
        // (no config, base ref missing, pushing the base branch itself, etc.).
        if let scoped = try collectScopedChangedFiles(
            update: update,
            workScope: config?.prePush.workScope,
            repoRoot: repoRoot,
        ) {
            files.formUnion(scoped)
            continue
        }

        // Fallback: original behavior.
        try files.formUnion(collectFallbackChangedFiles(
            update: update,
            remoteName: remoteName,
            repoRoot: repoRoot,
        ))
    }

    return files.sorted()
}

/// Collect changed files using a configured work-scope baseline. Returns nil if scope
/// can't be applied to this update (caller must fall back to default behavior).
private func collectScopedChangedFiles(
    update: GitPushUpdate,
    workScope: HooksConfig.WorkScopeConfig?,
    repoRoot: String,
) throws -> Set<String>? {
    guard let workScope else { return nil }

    // Bypass when pushing the baseline branch itself — we can't scope to a ref against itself.
    if isPushingBase(update: update, base: workScope.base) {
        printInfo("work-scope: pushing baseline '\(workScope.base)' — bypassing scope.")
        return nil
    }

    guard let baseSHA = try gitFirstLine(
        ["rev-parse", "--verify", "--quiet", workScope.base],
        repoRoot: repoRoot,
        allowFailure: true,
    ) else {
        printWarn("work-scope: base '\(workScope.base)' not found — falling back to default range.")
        return nil
    }

    guard let mergeBase = try gitFirstLine(
        ["merge-base", update.localSHA, baseSHA],
        repoRoot: repoRoot,
        allowFailure: true,
    ) else {
        printWarn("work-scope: no merge-base between HEAD and '\(workScope.base)' — falling back.")
        return nil
    }

    if mergeBase == update.localSHA {
        printOK("work-scope: HEAD is fully contained in '\(workScope.base)'. Nothing to check.")
        return []
    }

    let branch = BranchNameValidator.shortBranchName(fromRef: update.localRef)
    printInfo(
        "work-scope: base=\(workScope.base) merge-base=\(String(mergeBase.prefix(10))) walk=\(workScope.walk.rawValue)",
    )

    // Without a commit-filter, the tree diff between mergeBase and HEAD is the right answer
    // regardless of walk strategy: any commits brought in by an in-branch merge of `base`
    // are already part of the baseline tree, so they don't appear in the diff.
    guard let commitFilter = workScope.commitFilter else {
        return try Set(gitNullSeparated(
            ["diff", "--name-only", "--diff-filter=ACMR", "-z", mergeBase, update.localSHA, "--"],
            repoRoot: repoRoot,
        ))
    }

    // With a commit-filter we have to enumerate the commits, filter them, then union
    // their file diffs — we can't use a single tree-vs-tree diff because filtered commits
    // might still touch shared files.
    let revListArgs = workScope.walk == .firstParent
        ? ["rev-list", "--first-parent", "\(mergeBase)..\(update.localSHA)"]
        : ["rev-list", "\(mergeBase)..\(update.localSHA)"]
    let shas = try gitLines(revListArgs, repoRoot: repoRoot)

    var commits: [WorkScopeFilter.Commit] = []
    for sha in shas {
        let body = try runCommand(["git", "log", "-1", "--format=%B%x00%P", sha], currentDirectory: repoRoot)
        let raw = body.stdoutText
        // %B%x00%P → message NUL parents-line. Detect merge by parent count > 1.
        let parts = raw.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
        let message = parts.first.map(String.init) ?? raw
        let parents = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let isMerge = parents.split(separator: " ").count > 1
        commits.append(WorkScopeFilter.Commit(sha: sha, message: message, isMerge: isMerge))
    }

    let result = WorkScopeFilter.filter(commits: commits, branchName: branch, config: commitFilter)
    if let configError = result.configError {
        throw HookError.message(configError)
    }
    if let reason = result.disabledReason {
        printWarn("work-scope.commit-filter: \(reason) Falling back to all commits in scope.")
    } else if !result.dropped.isEmpty {
        let action = commitFilter.onMismatch
        let descriptor = result.branchIdentifier.map { "outside '\($0)'" } ?? "outside scope"
        let summary = "work-scope.commit-filter: dropped \(result.dropped.count) commit(s) \(descriptor)."
        switch action {
        case .skip:
            printInfo(summary)
        case .warn:
            printWarn(summary)
            for c in result.dropped {
                let title = c.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? c.message
                print("  - \(String(c.sha.prefix(10))) \(title)")
            }
        case .fail:
            printError(summary)
            for c in result.dropped {
                let title = c.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? c.message
                print("  - \(String(c.sha.prefix(10))) \(title)")
            }
            printWarn("Push blocked. Drop or re-author these commits and push again.")
            throw ExitCode(1)
        }
    }

    let kept = result.kept
    if kept.isEmpty {
        return []
    }

    var files = Set<String>()
    for commit in kept {
        // For merges, diff-tree's default per-parent output would inflate files; -m -1 picks
        // first-parent diff which matches our walk semantics.
        let args = commit.isMerge
            ? ["diff-tree", "--no-commit-id", "--name-only", "--diff-filter=ACMR", "-r", "-z", "-m", "-1", commit.sha]
            : ["diff-tree", "--no-commit-id", "--name-only", "--diff-filter=ACMR", "-r", "-z", commit.sha]
        try files.formUnion(gitNullSeparated(args, repoRoot: repoRoot))
    }
    return files
}

private func collectFallbackChangedFiles(
    update: GitPushUpdate,
    remoteName: String,
    repoRoot: String,
) throws -> Set<String> {
    var files = Set<String>()

    if update.isNewRemoteRef {
        if let defaultRemote = try gitFirstLine(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remoteName)/HEAD"],
            repoRoot: repoRoot,
            allowFailure: true,
        ),
            let mergeBase = try gitFirstLine(
                ["merge-base", update.localSHA, defaultRemote],
                repoRoot: repoRoot,
                allowFailure: true,
            ) {
            try files.formUnion(gitNullSeparated(
                ["diff", "--name-only", "--diff-filter=ACMR", "-z", mergeBase, update.localSHA, "--"],
                repoRoot: repoRoot,
            ))
            return files
        }

        for rev in try gitLines(
            ["rev-list", update.localSHA, "--not", "--remotes=\(remoteName)"],
            repoRoot: repoRoot,
        ) {
            try files.formUnion(gitNullSeparated(
                ["diff-tree", "--no-commit-id", "--name-only", "--diff-filter=ACMR", "-r", "-z", rev],
                repoRoot: repoRoot,
            ))
        }
        return files
    }

    try files.formUnion(gitNullSeparated(
        ["diff", "--name-only", "--diff-filter=ACMR", "-z", update.remoteSHA, update.localSHA, "--"],
        repoRoot: repoRoot,
    ))
    return files
}

/// Match the local push ref against the configured baseline.
/// Both "origin/develop" and "develop" base values match a push of `refs/heads/develop`.
private func isPushingBase(update: GitPushUpdate, base: String) -> Bool {
    let localBranch = BranchNameValidator.shortBranchName(fromRef: update.localRef)
    let baseBranch: String = if let slash = base.firstIndex(of: "/") {
        String(base[base.index(after: slash)...])
    } else {
        base
    }
    return localBranch == baseBranch
}

// MARK: - PR size check

private func runPRSizeCheck(
    config: HooksConfig?,
    updates: [GitPushUpdate],
    remoteName: String,
    repoRoot: String,
) throws {
    guard let prSize = config?.prePush.prSize else { return }

    let stats = try collectFileStats(
        config: config,
        updates: updates,
        remoteName: remoteName,
        repoRoot: repoRoot,
    )

    if stats.isEmpty {
        // Nothing to score — defer to the rest of the pipeline. We don't print here
        // because the changed-files block above already conveyed "no changes".
        return
    }

    let result = PRSizeMetric.compute(stats: stats, config: prSize)
    let score = result.score

    printSection("PR size check")
    printInfo(
        String(
            format: "Score %.2f (%@) — volume %.2f · scatter %.2f · entropy %.2f · test-ratio %.0f%%",
            score.cognitiveScore,
            score.band.label,
            score.volume,
            score.scatter,
            score.entropy,
            score.testRatio * 100,
        ),
    )
    printInfo(
        "Lines: +\(score.additions)/-\(score.deletions) prod"
            + " · +\(score.testAdditions)/-\(score.testDeletions) tests"
            + " · files: \(score.files) prod, \(score.testFiles) tests",
    )

    if result.violations.isEmpty {
        printOK("PR size within configured thresholds.")
        return
    }

    for violation in result.violations {
        printError(violation.message)
    }

    switch prSize.mode {
    case .warn:
        printWarn("PR size exceeds thresholds. Continuing because mode=warn.")
    case .fail:
        printWarn("Push blocked. Split the change into smaller PRs and try again.")
        throw ExitCode(1)
    }
}

private func collectFileStats(
    config: HooksConfig?,
    updates: [GitPushUpdate],
    remoteName: String,
    repoRoot: String,
) throws -> [PRSizeMetric.FileStat] {
    var byPath: [String: PRSizeMetric.FileStat] = [:]

    for update in updates {
        if HookLogic.shouldSkipUpdate(update) { continue }
        if let error = HookLogic.validateUpdateSHAs(update) {
            throw HookError.message(error)
        }

        let stats: [PRSizeMetric.FileStat] = if let scoped = try collectScopedFileStats(
            update: update,
            workScope: config?.prePush.workScope,
            repoRoot: repoRoot,
        ) {
            scoped
        } else {
            try collectFallbackFileStats(
                update: update,
                remoteName: remoteName,
                repoRoot: repoRoot,
            )
        }

        for stat in stats {
            if let existing = byPath[stat.path] {
                byPath[stat.path] = PRSizeMetric.FileStat(
                    path: stat.path,
                    added: existing.added + stat.added,
                    deleted: existing.deleted + stat.deleted,
                    isBinary: existing.isBinary || stat.isBinary,
                )
            } else {
                byPath[stat.path] = stat
            }
        }
    }

    return byPath.values.sorted { $0.path < $1.path }
}

private func collectScopedFileStats(
    update: GitPushUpdate,
    workScope: HooksConfig.WorkScopeConfig?,
    repoRoot: String,
) throws -> [PRSizeMetric.FileStat]? {
    guard let workScope else { return nil }
    if isPushingBase(update: update, base: workScope.base) { return nil }

    guard let baseSHA = try gitFirstLine(
        ["rev-parse", "--verify", "--quiet", workScope.base],
        repoRoot: repoRoot,
        allowFailure: true,
    ) else { return nil }

    guard let mergeBase = try gitFirstLine(
        ["merge-base", update.localSHA, baseSHA],
        repoRoot: repoRoot,
        allowFailure: true,
    ) else { return nil }

    if mergeBase == update.localSHA { return [] }

    // Commit-filter intentionally does NOT apply to PR size — reviewers must read the
    // actual tree delta regardless of which commits authored it. Teams that want to
    // exclude generated or vendored content should use the `exclude` patterns instead.
    return try numstatBetween(mergeBase, update.localSHA, repoRoot: repoRoot)
}

private func collectFallbackFileStats(
    update: GitPushUpdate,
    remoteName: String,
    repoRoot: String,
) throws -> [PRSizeMetric.FileStat] {
    if update.isNewRemoteRef {
        if let defaultRemote = try gitFirstLine(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remoteName)/HEAD"],
            repoRoot: repoRoot,
            allowFailure: true,
        ),
            let mergeBase = try gitFirstLine(
                ["merge-base", update.localSHA, defaultRemote],
                repoRoot: repoRoot,
                allowFailure: true,
            ) {
            return try numstatBetween(mergeBase, update.localSHA, repoRoot: repoRoot)
        }
        // Genuinely new branch with no remote default — skip rather than enumerate
        // every commit; the metric is most useful when there *is* a baseline.
        return []
    }

    return try numstatBetween(update.remoteSHA, update.localSHA, repoRoot: repoRoot)
}

private func numstatBetween(
    _ base: String,
    _ head: String,
    repoRoot: String,
) throws -> [PRSizeMetric.FileStat] {
    let result = try runCommand(
        ["git", "diff", "--no-renames", "--numstat", "-z", "--diff-filter=ACMR", base, head, "--"],
        currentDirectory: repoRoot,
    )
    guard result.exitCode == 0 else {
        let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw HookError.message("git diff --numstat failed: \(stderr)")
    }
    return PRSizeMetric.parseNumstatZ(result.stdout)
}
