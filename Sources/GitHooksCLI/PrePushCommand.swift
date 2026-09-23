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
        Interruption.install()
        do {
            try runChecks()
        } catch let interruption as Interrupted {
            printWarn("Interrupted by signal \(interruption.signal). Stopped the running command and cleaned up.")
            throw ExitCode(128 + interruption.signal)
        }
    }

    private func runChecks() throws {
        let repoRoot = try gitRepoRoot()
        let resolved = try HooksConfig.resolve(repoRoot: repoRoot)
        let config = resolved?.config
        let trusted = try RepositoryTrust.isTrusted(repoRoot: repoRoot)

        printSection("Pre-push checks")
        if let resolved { printInfo("Config: \(resolved.sourceDescription)") }
        printInfo("Remote: \(remoteName) (\(remoteURL))")

        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let stdin = String(data: stdinData, encoding: .utf8) ?? ""
        let updates = HookLogic.parsePushUpdates(from: stdin)

        // --- Step 1a: Branch-name validation (from config) ---
        try runBranchNameValidation(config: config, updates: updates)

        // --- Step 1b: Commit message validation (from config) ---
        try runCommitValidation(config: config, updates: updates, remoteName: remoteName, repoRoot: repoRoot)

        // --- Step 2: Collect the pushed commits and the files that each one changes ---
        let commits = try collectPushedCommits(
            config: config,
            updates: updates,
            remoteName: remoteName,
            repoRoot: repoRoot,
        )

        guard commits.contains(where: { !$0.files.isEmpty }) else {
            printOK("No source changes detected. Skipping checks.")
            return
        }

        // --- Step 2c: PR size check (config-driven) ---
        try runPRSizeCheck(
            config: config,
            updates: updates,
            remoteName: remoteName,
            repoRoot: repoRoot,
        )

        // --- Steps 3-5: Check each pushed commit as the push sends it, not the working tree ---
        let place = try trusted ? VerificationPlace(repoRoot: repoRoot) : nil
        // The worktree and the build directories of a repository serve one run at a time.
        let lock = try place.map { place in
            try FileLock(path: place.lockPath) {
                printInfo("Waiting for another project-hooks run in this repository to finish...")
            }
        }
        for commit in commits where !commit.files.isEmpty {
            try check(commit, config: config, place: place, repoRoot: repoRoot)
        }
        _ = consume lock

        printOK("pre-push checks completed successfully.")
    }
}

// MARK: - Pushed commits

/// A commit that the push sends, the branches or refs that it updates, and the files that it changes.
private struct PushedCommit {
    let sha: String
    var refs: [String]
    var files: [String]
}

/// Where a trusted repository's pushed commits are checked out, where their builds go, and which results they reuse.
private struct VerificationPlace {
    let repositoryKey: String
    let buildCache = BuildCache.standard()
    let results = ResultCache.standard()

    init(repoRoot: String) throws {
        repositoryKey = try HookCache.repositoryKey(repoRoot: repoRoot)
    }

    /// The same path for every push of the repository, so that builds see the same source paths each time.
    var worktreePath: String {
        "\(HookCache.root)/worktrees/\(repositoryKey)"
    }

    var lockPath: String {
        "\(HookCache.root)/locks/\(repositoryKey).lock"
    }

    /// Run `command` in `directory`, with its build output in the build directory of `module`, a path relative to the
    /// repository root, when the tool takes one.
    ///
    /// Gradle keeps its own caches, and other tools have no build directory, so they run as they are.
    func runBuilding(
        _ command: [String],
        module: String,
        in directory: String,
        timeout: TimeInterval,
    ) throws -> CommandResult {
        let run = { (command: [String]) throws -> CommandResult in
            printInfo("Command: \(command.joined(separator: " "))")
            printInfo("Timeout: \(Int(timeout))s")
            return try runCommand(command, currentDirectory: directory, timeoutSeconds: timeout)
        }
        guard BuildIsolation.inject(into: command, scratchPath: "") != command else {
            return try run(command)
        }
        let entry = buildCache.entry(repositoryKey: repositoryKey, module: module)
        return try buildCache.use(entry) { try run(BuildIsolation.inject(into: command, scratchPath: entry.path)) }
    }

    /// The key of the result that `command` gives for `module` on the tree that `checkout` holds.
    func resultKey(kind: String, module: String, command: [String], checkout: Checkout) throws -> String {
        try ResultCache.key(
            kind: kind,
            tree: checkout.tree,
            module: module,
            command: command,
            root: checkout.root,
            tools: ToolVersions.of(command, in: checkout.root),
            environment: mergedEnvironment(),
        )
    }
}

/// A pushed commit checked out in a worktree.
private struct Checkout {
    let root: String
    /// The hash of the commit's tree, which identifies its content whatever the commit's message or parents.
    let tree: String
}

private func reportCachedPass(_ what: String) {
    printOK("\(what) passed on this tree before, with the same tools and configuration. Skipping.")
    printInfo("To run them anyway, set GITHOOKS_NO_CACHE=1.")
}

/// Lint the commit's files from a snapshot of the commit.
///
/// In a trusted repository, which has a `place`, also run the custom tasks, the builds and the tests in a worktree at
/// the commit.
private func check(_ commit: PushedCommit, config: HooksConfig?, place: VerificationPlace?, repoRoot: String) throws {
    printSection("Commit \(commit.sha.prefix(10)) (\(commit.refs.joined(separator: ", ")))")
    printInfo("Changed files: \(commit.files.count)")
    for file in commit.files {
        print("  - \(file)")
    }

    // --- Step 3: Lint ---
    let workingTreePlatform = ProjectDetector.detectPlatform(repoRoot: repoRoot)
    let lintPlatform = resolveEffectivePlatform(changedFiles: commit.files, detected: workingTreePlatform)
    try runLintChecks(commit: commit, platform: lintPlatform, repoRoot: repoRoot, trusted: place != nil)

    let tasks = config?.prePush.tasks ?? []
    guard let place else {
        if !tasks.isEmpty {
            RepositoryTrust.reportSkipped("\(tasks.count) custom task(s)")
        }
        if hasTests(config: config, changedFiles: commit.files, platform: lintPlatform, repoRoot: repoRoot) {
            RepositoryTrust.reportSkipped("tests and builds")
        }
        return
    }

    let worktree = try VerificationWorktree.create(commit: commit.sha, repoRoot: repoRoot, path: place.worktreePath)
    defer { worktree.remove(repoRoot: repoRoot) }
    let tree = try gitFirstLine(["rev-parse", "\(commit.sha)^{tree}"], repoRoot: repoRoot) ?? commit.sha
    let checkout = Checkout(root: worktree.path, tree: tree)
    try worktree.inScope {
        // --- Step 4: Custom pre-push tasks ---
        try runCustomTasks(tasks, files: commit.files, repoRoot: worktree.path, blockMessage: "Push")

        // --- Step 5: Test + build ---
        let platform = resolveEffectivePlatform(
            changedFiles: commit.files,
            detected: ProjectDetector.detectPlatform(repoRoot: worktree.path),
        )
        try runTestChecks(
            config: config,
            changedFiles: commit.files,
            platform: platform,
            checkout: checkout,
            place: place,
        )
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

    // Commit-message validation checks the commits this push introduces — reachable from the
    // pushed tip but not from any remote-tracking ref — so a malformed *new* commit is caught
    // while upstream history a rebased branch merely inherited is not re-validated. An
    // explicit `commit-message.base` narrows the set further by also excluding that ref.
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

private func runLintChecks(commit: PushedCommit, platform: Platform, repoRoot: String, trusted: Bool) throws {
    let linters = discoverLinters(platform: platform, repoRoot: repoRoot, trusted: trusted)

    guard !linters.isEmpty else {
        printWarn("No linters found. Skipping lint checks.")
        return
    }

    printInfo("Discovered linters: \(linters.map(\.name).joined(separator: ", "))")
    let lintable = LinterDiscovery.filterFiles(commit.files, forPlatform: .mixed)
    let snapshot = try IndexSnapshot.take(repoRoot: repoRoot, paths: lintable, commit: commit.sha)
    defer { snapshot.remove() }
    let workspace = LintWorkspace(snapshot: snapshot, repoRoot: repoRoot)
    for linter in linters {
        try runLinterGrouped(linter, files: snapshot.files, workspace: workspace, blockMessage: "Push")
    }
}

// MARK: - Test + build

private func runTestChecks(
    config: HooksConfig?,
    changedFiles: [String],
    platform: Platform,
    checkout: Checkout,
    place: VerificationPlace,
) throws {
    // Config-driven test override
    if let override = config?.prePush.testOverride {
        if override.skip {
            printSection("Tests (config override: skipped)")
            printInfo("Test stage disabled by .project-hooks.yml (test-override.skip: true).")
            return
        }
        try runTestOverride(override, changedFiles: changedFiles, checkout: checkout, place: place)
        return
    }

    // Auto-detected module testing
    let modules = TestTargetResolver.detectModules(
        changedFiles: changedFiles,
        repoRoot: checkout.root,
        platform: platform,
    )

    if modules.isEmpty {
        printOK("No test targets detected for changed files. Skipping tests.")
        return
    }

    try runModuleTests(modules: modules, checkout: checkout, place: place)

    let untestedModules = modules.filter(\.testCommand.isEmpty)
    if !untestedModules.isEmpty {
        try runModuleBuilds(modules: untestedModules, checkout: checkout, place: place)
    }
}

/// Whether `runTestChecks` would run a test or build command for these changes.
private func hasTests(config: HooksConfig?, changedFiles: [String], platform: Platform, repoRoot: String) -> Bool {
    if let override = config?.prePush.testOverride {
        return !override.skip
    }
    return !TestTargetResolver.detectModules(changedFiles: changedFiles, repoRoot: repoRoot, platform: platform)
        .isEmpty
}

private func runTestOverride(
    _ override: HooksConfig.TestOverride,
    changedFiles: [String],
    checkout: Checkout,
    place: VerificationPlace,
) throws {
    let testTimeout = timeoutFromEnv("GITHOOKS_TEST_TIMEOUT_SECONDS", defaultSeconds: 1200)

    guard var command = try buildOverrideCommand(override, changedFiles: changedFiles, repoRoot: checkout.root) else {
        return
    }

    if let extra = override.extraArgs, !extra.isEmpty {
        command.append(contentsOf: extra)
    }

    printSection("Tests (config override: \(override.type.rawValue))")
    let key = try place.resultKey(kind: "test", module: "test-override", command: command, checkout: checkout)
    if place.results.hasPassed(key) {
        reportCachedPass("Tests")
        return
    }

    let result = try place.runBuilding(command, module: "test-override", in: checkout.root, timeout: testTimeout)
    let outcome = diagnoseTestResult(result, moduleName: override.type.rawValue, timeout: testTimeout)

    switch outcome {
        case .passed, .noOp:
            place.results.recordPass(key)
        case .timedOut, .failed:
            throw ExitCode(1)
    }
}

/// Default xcodebuild destination when neither `GITHOOKS_DESTINATION` nor
/// `test-override.destination` is set. `generic/platform=iOS Simulator` lets
/// xcodebuild pick the best available simulator instead of relying on a
/// hardcoded model name that may not exist after Xcode/SDK upgrades.
let defaultIOSDestination = "generic/platform=iOS Simulator"

private func buildOverrideCommand(
    _ override: HooksConfig.TestOverride,
    changedFiles: [String],
    repoRoot: String,
) throws -> [String]? {
    let destination =
        ProcessInfo.processInfo.environment["GITHOOKS_DESTINATION"]
        ?? override.destination
        ?? defaultIOSDestination

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
            let trimmed = override.task?.trimmingCharacters(in: .whitespaces)
            let task = (trimmed?.isEmpty == false) ? (trimmed ?? "test") : "test"
            return [wrapper, task]
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
    guard resolution.loadedFromXCTestPlan else {
        throw HookError.message(
            "Could not load test plan: \(resolution.xctestplanPath). "
                + "Fix the test-plan path in .project-hooks.yml.",
        )
    }
    printInfo("Loaded bundles from: \(resolution.xctestplanPath)")

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

private func runModuleTests(modules: [DetectedModule], checkout: Checkout, place: VerificationPlace) throws {
    let testTimeout = timeoutFromEnv("GITHOOKS_TEST_TIMEOUT_SECONDS", defaultSeconds: 1200)

    for module in modules where !module.testCommand.isEmpty {
        printSection("Tests: \(module.name)")
        let key = try place.resultKey(
            kind: "test", module: module.path, command: module.testCommand, checkout: checkout)
        if place.results.hasPassed(key) {
            reportCachedPass("Tests")
            continue
        }

        let result = try place.runBuilding(
            module.testCommand,
            module: module.path,
            in: checkout.root,
            timeout: testTimeout,
        )
        let outcome = diagnoseTestResult(result, moduleName: module.name, timeout: testTimeout)

        switch outcome {
            case .passed, .noOp:
                place.results.recordPass(key)
            case .timedOut, .failed:
                throw ExitCode(1)
        }
    }
}

private func runModuleBuilds(modules: [DetectedModule], checkout: Checkout, place: VerificationPlace) throws {
    let buildTimeout = timeoutFromEnv("GITHOOKS_BUILD_TIMEOUT_SECONDS", defaultSeconds: 600)

    for module in modules where !module.buildCommand.isEmpty {
        printSection("Build: \(module.name)")
        let key = try place.resultKey(
            kind: "build",
            module: module.path,
            command: module.buildCommand,
            checkout: checkout,
        )
        if place.results.hasPassed(key) {
            reportCachedPass("The build")
            continue
        }

        let result = try place.runBuilding(
            module.buildCommand,
            module: module.path,
            in: checkout.root,
            timeout: buildTimeout,
        )

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
        place.results.recordPass(key)
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
        let args = HookLogic.commitMessageRevListArgs(
            localSHA: update.localSHA,
            remoteName: remoteName,
            excludeBase: excludeBase,
        )
        try shas.append(contentsOf: gitLines(args, repoRoot: repoRoot))
    }
    return shas
}

/// Resolve the `commit-message.base` ref to a SHA.
///
/// Returns nil when the field is unset
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

/// The distinct commits that the push sends, in the order of the updates, each with the files that it changes relative
/// to what the remote has.
///
/// Tags and deletions are skipped.
private func collectPushedCommits(
    config: HooksConfig?,
    updates: [GitPushUpdate],
    remoteName: String,
    repoRoot: String,
) throws -> [PushedCommit] {
    var commits: [PushedCommit] = []

    for update in updates {
        if HookLogic.shouldSkipUpdate(update) { continue }
        if let error = HookLogic.validateUpdateSHAs(update) {
            throw HookError.message(error)
        }

        // Try work-scope first. Returns nil when scope is disabled or doesn't apply
        // (no config, base ref missing, pushing the base branch itself, etc.).
        let files =
            try collectScopedChangedFiles(
                update: update,
                workScope: config?.prePush.workScope,
                repoRoot: repoRoot,
            ) ?? collectFallbackChangedFiles(update: update, remoteName: remoteName, repoRoot: repoRoot)

        let ref = BranchNameValidator.shortBranchName(fromRef: update.localRef)
        if let index = commits.firstIndex(where: { $0.sha == update.localSHA }) {
            commits[index].refs.append(ref)
            commits[index].files = Set(commits[index].files).union(files).sorted()
        } else {
            commits.append(PushedCommit(sha: update.localSHA, refs: [ref], files: files.sorted()))
        }
    }

    return commits
}

/// Collect changed files using a configured work-scope baseline.
///
/// Returns nil if scope
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

    guard
        let baseSHA = try gitFirstLine(
            ["rev-parse", "--verify", "--quiet", workScope.base],
            repoRoot: repoRoot,
            allowFailure: true,
        )
    else {
        printWarn("work-scope: base '\(workScope.base)' not found — falling back to default range.")
        return nil
    }

    guard
        let mergeBase = try gitFirstLine(
            ["merge-base", update.localSHA, baseSHA],
            repoRoot: repoRoot,
            allowFailure: true,
        )
    else {
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
        return try Set(
            gitNullSeparated(
                ["diff", "--name-only", "--diff-filter=ACMR", "-z", mergeBase, update.localSHA, "--"],
                repoRoot: repoRoot,
            ))
    }

    // With a commit-filter we have to enumerate the commits, filter them, then union
    // their file diffs — we can't use a single tree-vs-tree diff because filtered commits
    // might still touch shared files.
    let revListArgs =
        workScope.walk == .firstParent
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
        let args =
            commit.isMerge
            ? ["diff-tree", "--no-commit-id", "--name-only", "--diff-filter=ACMR", "-r", "-z", "-m", "-1", commit.sha]
            : ["diff-tree", "--root", "--no-commit-id", "--name-only", "--diff-filter=ACMR", "-r", "-z", commit.sha]
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
            )
        {
            try files.formUnion(
                gitNullSeparated(
                    ["diff", "--name-only", "--diff-filter=ACMR", "-z", mergeBase, update.localSHA, "--"],
                    repoRoot: repoRoot,
                ))
            return files
        }

        for rev in try gitLines(
            ["rev-list", update.localSHA, "--not", "--remotes=\(remoteName)"],
            repoRoot: repoRoot,
        ) {
            try files.formUnion(
                gitNullSeparated(
                    // Without `--root`, diff-tree lists nothing for a repository's first commit.
                    ["diff-tree", "--root", "--no-commit-id", "--name-only", "--diff-filter=ACMR", "-r", "-z", rev],
                    repoRoot: repoRoot,
                ))
        }
        return files
    }

    try files.formUnion(
        gitNullSeparated(
            ["diff", "--name-only", "--diff-filter=ACMR", "-z", update.remoteSHA, update.localSHA, "--"],
            repoRoot: repoRoot,
        ))
    return files
}

/// Match the local push ref against the configured baseline.
///
/// Both "origin/develop" and "develop" base values match a push of `refs/heads/develop`.
private func isPushingBase(update: GitPushUpdate, base: String) -> Bool {
    let localBranch = BranchNameValidator.shortBranchName(fromRef: update.localRef)
    let baseBranch: String =
        if let slash = base.firstIndex(of: "/") {
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

    try reportPRSize(stats: stats, config: prSize, blockMessage: "Push")
}

/// Render the PR-size score and decide whether to block.
///
/// Shared by the pre-commit
/// and pre-push hooks so both surface identical formatting and thresholds.
func reportPRSize(
    stats: [PRSizeMetric.FileStat],
    config: HooksConfig.PRSizeConfig,
    blockMessage: String,
) throws {
    let result = PRSizeMetric.compute(stats: stats, config: config)
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

    switch config.mode {
        case .warn:
            printWarn("PR size exceeds thresholds. Continuing because mode=warn.")
        case .fail:
            printWarn("\(blockMessage) blocked. Split the change into smaller PRs and try again.")
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

        let stats: [PRSizeMetric.FileStat] =
            if let scoped = try collectScopedFileStats(
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

    guard
        let baseSHA = try gitFirstLine(
            ["rev-parse", "--verify", "--quiet", workScope.base],
            repoRoot: repoRoot,
            allowFailure: true,
        )
    else { return nil }

    guard
        let mergeBase = try gitFirstLine(
            ["merge-base", update.localSHA, baseSHA],
            repoRoot: repoRoot,
            allowFailure: true,
        )
    else { return nil }

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
            )
        {
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
