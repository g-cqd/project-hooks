import ArgumentParser
import Foundation
import GitHooksCore

struct TrustCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Let project-hooks run a repository's own code",
        discussion: """
            Until you trust a repository, its hooks run only linters and commit checks. Trusting it also runs its custom
            tasks, its builds and tests on push, and linters that it builds itself. Everything that a clone brings can
            then run on your next commit or push, so trust only repositories whose code you would run yourself.

              project-hooks trust                 Trust the current repository
              project-hooks trust --path <repo>   Trust another repository
              project-hooks trust --revoke        Stop trusting the current repository
            """,
    )

    @Option(help: "Path to the repository. Defaults to the current repository.")
    var path: String?

    @Flag(help: "Stop trusting the repository.")
    var revoke = false

    func run() throws {
        let repoRoot = try path.map { try repositoryRoot(of: $0) } ?? gitRepoRoot()
        try RepositoryTrust.setTrusted(!revoke, repoRoot: repoRoot)

        if revoke {
            printOK("\(repoRoot) is no longer trusted. Its hooks run only linters and commit checks.")
        } else {
            printOK("\(repoRoot) is trusted. Its hooks also run its custom tasks, builds and tests.")
        }
        if try RepositoryTrust.isTrusted(repoRoot: repoRoot) == revoke {
            printWarn("Another git configuration scope sets \(RepositoryTrust.configKey), and it takes precedence.")
        }
    }

    private func repositoryRoot(of directory: String) throws -> String {
        let result = try runCommand(["git", "-C", directory, "rev-parse", "--show-toplevel"])
        guard result.exitCode == 0 else {
            printError("\(directory) is not a git repository.")
            throw ExitCode(1)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
