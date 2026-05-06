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
