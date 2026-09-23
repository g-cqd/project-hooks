import Foundation

/// Remembers which test and build commands passed on which tree, so that pushing an identical tree again, for example
/// to a second remote or after rewording a commit message, does not run them again.
///
/// A result applies only to the same tree, module and command, with the same tool versions and the same environment
/// variables that select a toolchain. `GITHOOKS_NO_CACHE=1` makes every command run.
struct ResultCache {
    /// Variables that select the toolchain or the SDK that a command builds with.
    static let toolchainVariables = ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT", "JAVA_HOME"]

    let directory: String
    let isEnabled: Bool
    /// The most results kept.
    ///
    /// Recording a result beyond it removes the least recently used ones.
    var capacity = 5000

    static func standard() -> ResultCache {
        ResultCache(
            directory: HookCache.root + "/results",
            isEnabled: ProcessInfo.processInfo.environment["GITHOOKS_NO_CACHE"] != "1",
        )
    }

    /// The key of a command's result.
    /// - Parameters:
    ///   - kind: What the command does, such as "test".
    ///   - tree: The hash of the tree that the command runs on.
    ///   - module: The module path, relative to the repository root.
    ///   - command: The command, with `root` standing for the checkout it runs in.
    ///   - root: The checkout's path, which the key leaves out.
    ///   - tools: The versions of the tools that the command runs.
    ///   - environment: The environment that the command runs with.
    /// - Returns: A hexadecimal digest of all of these.
    static func key(
        kind: String,
        tree: String,
        module: String,
        command: [String],
        root: String,
        tools: String,
        environment: [String: String],
    ) -> String {
        let portableCommand = command.map { $0.replacingOccurrences(of: root, with: "<root>") }
        let variables = toolchainVariables.map { "\($0)=\(environment[$0] ?? "")" }
        return HookCache.digest(
            ["project-hooks result v1", projectHooksVersion, kind, tree, module, tools]
                + portableCommand + ["--"] + variables,
        )
    }

    /// Whether a command with this key passed before.
    ///
    /// A hit counts as a use.
    func hasPassed(_ key: String) -> Bool {
        let path = "\(directory)/\(key)"
        guard isEnabled, FileManager.default.fileExists(atPath: path) else { return false }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        return true
    }

    /// Record that a command with this key passed.
    func recordPass(_ key: String) {
        recordPasses([key])
    }

    /// Record that the commands or files with these keys passed.
    func recordPasses(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for key in keys {
                FileManager.default.createFile(atPath: "\(directory)/\(key)", contents: nil)
            }
            try trim()
        } catch {
            printWarn("Could not record a passing result in \(directory): \(error)")
        }
    }

    /// Remove the least recently used results beyond `capacity`.
    private func trim() throws {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: directory)
        guard names.count > capacity else { return }

        let byLastUse = names.map { name in
            let date = (try? fileManager.attributesOfItem(atPath: "\(directory)/\(name)"))?[.modificationDate] as? Date
            return (name: name, lastUse: date ?? .distantPast)
        }.sorted { $0.lastUse < $1.lastUse }
        for result in byLastUse.prefix(names.count - capacity) {
            try? fileManager.removeItem(atPath: "\(directory)/\(result.name)")
        }
    }
}

/// The versions of the tools that a command runs, which a cached result must match.
enum ToolVersions {
    /// A description of the tool that `command` runs, from `swift --version` or `xcodebuild -version`.
    ///
    /// The probe runs in `directory`, so that swiftly applies the `.swift-version` there. Gradle's version comes from
    /// the wrapper, which is in the tree.
    static func of(_ command: [String], in directory: String) throws -> String {
        guard let executable = command.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return "" }
        let probe: [String] =
            switch executable {
                case "swift": ["swift", "--version"]
                case "xcodebuild": ["xcodebuild", "-version"]
                default: []
            }
        guard !probe.isEmpty else { return executable }

        let result = try runCommand(probe, currentDirectory: directory, timeoutSeconds: 60)
        guard result.exitCode == 0 else {
            throw HookError.message("\(probe.joined(separator: " ")) failed: \(result.stderrText)")
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
