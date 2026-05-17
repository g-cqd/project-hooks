import ArgumentParser
import Foundation
import GitHooksCore

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install git hooks into a repository or globally",
        discussion: """
            Modes:
              project-hooks install           Install into the current repository
              project-hooks install --global  Install into git templates (applies to new clones)
              project-hooks install --path /path/to/repo  Install into a specific repository
            """,
    )

    @Flag(help: "Install into ~/.git-templates/hooks (applies to all new git clones)")
    var global = false

    @Option(help: "Path to a git repository to install hooks into")
    var path: String?

    func run() throws {
        let binaryPath = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardized.path

        if global {
            try installGlobal(binaryPath: binaryPath)
        } else if let repoPath = path {
            try installToRepo(repoPath: repoPath, binaryPath: binaryPath)
        } else {
            try installLocal(binaryPath: binaryPath)
        }
    }

    private func installGlobal(binaryPath: String) throws {
        let templateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".git-templates/hooks").path

        let installed = try HookInstaller.installHooks(to: templateDir, binaryPath: binaryPath)
        for hookPath in installed {
            printOK("Installed \(URL(fileURLWithPath: hookPath).lastPathComponent) at \(hookPath)")
        }

        let result = try runCommand([
            "git",
            "config",
            "--global",
            "init.templateDir",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".git-templates").path,
        ])
        guard result.exitCode == 0 else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.message("Failed to configure git template directory: \(stderr)")
        }

        printOK("Git configured to use ~/.git-templates for new repositories.")
    }

    private func installToRepo(repoPath: String, binaryPath: String) throws {
        let hooksPathResult = try runCommand([
            "git",
            "-C",
            repoPath,
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "hooks",
        ])
        guard hooksPathResult.exitCode == 0 else {
            printError("\(repoPath) is not a git repository.")
            throw ExitCode(1)
        }

        let hooksDir = hooksPathResult.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hooksDir.isEmpty else {
            throw HookError.message("Could not resolve hooks directory for \(repoPath).")
        }

        let installed = try HookInstaller.installHooks(to: hooksDir, binaryPath: binaryPath)
        for hookPath in installed {
            printOK("Installed \(URL(fileURLWithPath: hookPath).lastPathComponent) at \(hookPath)")
        }
    }

    private func installLocal(binaryPath: String) throws {
        let repoRoot = try gitRepoRoot()
        try installToRepo(repoPath: repoRoot, binaryPath: binaryPath)
    }

    private func gitRepoRoot() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--show-toplevel"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            printError("Run this command inside a git repository.")
            throw ExitCode(1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
