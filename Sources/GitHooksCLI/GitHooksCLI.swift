import ArgumentParser

@main
struct GitHooksCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project-hooks",
        abstract: "Git hooks engine for Swift and Android projects",
        discussion: """
        Auto-detects platform (iOS/Android), available linters, and project structure.
        Configure custom tasks, commit message rules, and test overrides via
        .project-hooks.yml in the repo root.
        """,
        version: projectHooksVersion,
        subcommands: [PreCommitCommand.self, PrePushCommand.self, InstallCommand.self],
    )
}
