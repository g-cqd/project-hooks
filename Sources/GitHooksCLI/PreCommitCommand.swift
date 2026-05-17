import ArgumentParser
import Foundation
import GitHooksCore

struct PreCommitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pre-commit",
        abstract: "Run pre-commit checks (auto-detects platform and linters)",
    )

    mutating func run() throws {
        let repoRoot = try gitRepoRoot()
        let resolved = try HooksConfig.resolve(repoRoot: repoRoot)
        let config = resolved?.config
        let platform = ProjectDetector.detectPlatform(repoRoot: repoRoot)

        printSection("Pre-commit checks")
        printInfo("Platform: \(platform.rawValue)")
        if let resolved { printInfo("Config: \(resolved.sourceDescription)") }

        // --- Step 1: Collect all staged files ---
        let allStaged = try collectStagedFiles(repoRoot: repoRoot)

        if allStaged.isEmpty {
            printOK("No staged files. Nothing to check.")
            return
        }

        // --- Step 1b: PR size check (config-driven, branch-cumulative) ---
        try runPreCommitPRSizeCheck(config: config, repoRoot: repoRoot)

        // --- Step 2: Run custom tasks from config ---
        try runCustomTasks(
            config?.preCommit.tasks ?? [],
            files: allStaged,
            repoRoot: repoRoot,
            blockMessage: "Commit",
        )

        // --- Step 3: Auto-detect and run all available linters ---
        let effectivePlatform = ProjectDetector.detectPlatformFromFiles(allStaged)
        let resolvedPlatform = effectivePlatform != .unknown ? effectivePlatform : platform

        let linters = LinterDiscovery.discoverLinters(
            forPlatform: resolvedPlatform,
            repoRoot: repoRoot,
            fallbackPaths: defaultLinterFallbackPaths,
        )

        if linters.isEmpty {
            printWarn("No linters found for platform \(resolvedPlatform.rawValue). Skipping lint checks.")
        } else {
            printInfo("Discovered linters: \(linters.map(\.name).joined(separator: ", "))")
            for linter in linters {
                try runLinterGrouped(linter, files: allStaged, repoRoot: repoRoot, blockMessage: "Commit")
            }
        }

        printOK("pre-commit checks completed successfully.")
    }
}

// MARK: - PR size check (pre-commit, branch-cumulative)

/// Runs the PR-size check at commit time using a branch-cumulative diff.
///
/// Uses `merge-base(HEAD, base)..index`. This is the early-warning sibling of the
/// pre-push check — it scores what the PR *would* look like if this commit
/// shipped right now, so reviewers don't only discover an oversized change at
/// push time.
///
/// The baseline is reused from `pre-push.work-scope.base`. When it isn't
/// configured (or can't be resolved), a warning is printed and the check is
/// skipped: blocking commits over a config gap would be more obstructive than
/// the check is worth.
private func runPreCommitPRSizeCheck(
    config: HooksConfig?,
    repoRoot: String,
) throws {
    guard let prSize = config?.preCommit.prSize else { return }

    guard let base = config?.prePush.workScope?.base, !base.isEmpty else {
        printWarn("pre-commit pr-size: no pre-push.work-scope.base configured — skipping.")
        return
    }

    guard
        let baseSHA = try gitFirstLine(
            ["rev-parse", "--verify", "--quiet", base],
            repoRoot: repoRoot,
            allowFailure: true,
        )
    else {
        printWarn("pre-commit pr-size: base '\(base)' not found — skipping.")
        return
    }

    // HEAD may be unborn on the very first commit; merge-base needs both sides.
    let head = try gitFirstLine(
        ["rev-parse", "--verify", "--quiet", "HEAD"],
        repoRoot: repoRoot,
        allowFailure: true,
    )

    let diffBase: String =
        if let head,
            let mergeBase = try gitFirstLine(
                ["merge-base", head, baseSHA],
                repoRoot: repoRoot,
                allowFailure: true,
            )
        {
            mergeBase
        } else {
            // No HEAD (initial commit) or disjoint history: fall back to comparing
            // the index directly against the baseline ref.
            baseSHA
        }

    let result = try runCommand(
        ["git", "diff", "--no-renames", "--numstat", "-z", "--diff-filter=ACMR", "--cached", diffBase, "--"],
        currentDirectory: repoRoot,
    )
    guard result.exitCode == 0 else {
        let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw HookError.message("git diff --cached --numstat failed: \(stderr)")
    }

    let stats = PRSizeMetric.parseNumstatZ(result.stdout)
    if stats.isEmpty { return }

    try reportPRSize(stats: stats, config: prSize, blockMessage: "Commit")
}
