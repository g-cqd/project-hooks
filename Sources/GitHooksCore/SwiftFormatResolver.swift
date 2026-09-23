import Foundation

/// Chooses the swift-format binary for a repository without consulting `PATH`.
///
/// `PATH` differs between a terminal and a git client launched from the Dock, so a `PATH` lookup could lint the same
/// staged files with different swift-format versions and reach different verdicts.
public enum SwiftFormatResolver {
    /// The swift-format binary to run, and where it came from.
    public struct Resolution: Equatable, Sendable {
        public let executablePath: String
        /// Where the binary came from, for the hook's output.
        public let origin: String
        /// Why the repository's own toolchain was not used, when it was not.
        public let fallbackReason: String?
    }

    /// The effects that resolution needs, injectable for tests.
    public struct Probe: Sendable {
        public var isExecutable: @Sendable (String) -> Bool
        public var readFile: @Sendable (String) -> String?
        /// Run a command in a directory, and return its exit status and standard output, or nil if it cannot start.
        public var run:
            @Sendable (_ command: [String], _ currentDirectory: String) -> (
                exitCode: Int32,
                output: String,
            )?

        public init(
            isExecutable: @escaping @Sendable (String) -> Bool,
            readFile: @escaping @Sendable (String) -> String?,
            run: @escaping @Sendable ([String], String) -> (exitCode: Int32, output: String)?,
        ) {
            self.isExecutable = isExecutable
            self.readFile = readFile
            self.run = run
        }

        public static let live = Probe(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
            run: runProcess,
        )
    }

    /// Where swiftly installs itself, in the order they are tried.
    public static func swiftlyLocations(home: String) -> [String] {
        ["\(home)/.swiftly/bin/swiftly", "/opt/homebrew/bin/swiftly", "/usr/local/bin/swiftly"]
    }

    /// The swift-format binary for the repository at `repoRoot`.
    ///
    /// When `repoRoot` holds a `.swift-version`, the binary comes from the toolchain that swiftly selects for it.
    /// Otherwise, or when swiftly or that toolchain is missing, it comes from the toolchain that `xcode-select` or
    /// `DEVELOPER_DIR` selects, through `/usr/bin/xcrun`.
    /// - Parameters:
    ///   - repoRoot: The repository's working tree, whose `.swift-version` applies.
    ///   - home: The user's home directory.
    ///   - probe: The file system and process access to use.
    /// - Returns: The resolution, or nil when neither source provides swift-format.
    public static func resolve(repoRoot: String, home: String, probe: Probe = .live) -> Resolution? {
        var fallbackReason: String?
        let versionFile = URL(fileURLWithPath: repoRoot).appendingPathComponent(".swift-version").path
        if let version = probe.readFile(versionFile).flatMap(firstLine) {
            switch toolchainSwiftFormat(version: version, repoRoot: repoRoot, home: home, probe: probe) {
                case .success(let resolution):
                    return resolution
                case .failure(let reason):
                    fallbackReason = reason.message
            }
        }

        guard let found = probe.run(["/usr/bin/xcrun", "--find", "swift-format"], repoRoot),
            found.exitCode == 0,
            let path = firstLine(found.output),
            probe.isExecutable(path)
        else {
            return nil
        }
        return Resolution(executablePath: path, origin: "Xcode toolchain, via xcrun", fallbackReason: fallbackReason)
    }

    private struct Unavailable: Error {
        let message: String
    }

    private static func toolchainSwiftFormat(
        version: String,
        repoRoot: String,
        home: String,
        probe: Probe,
    ) -> Result<Resolution, Unavailable> {
        guard let swiftly = swiftlyLocations(home: home).first(where: probe.isExecutable) else {
            return .failure(Unavailable(message: ".swift-version names \(version), but swiftly is not installed"))
        }
        // swiftly reads `.swift-version` from its working directory.
        guard let located = probe.run([swiftly, "use", "--print-location"], repoRoot),
            located.exitCode == 0,
            let toolchain = lastLine(located.output)
        else {
            return .failure(Unavailable(message: ".swift-version names \(version), which swiftly has not installed"))
        }
        let path = URL(fileURLWithPath: toolchain).appendingPathComponent("usr/bin/swift-format").path
        guard probe.isExecutable(path) else {
            return .failure(Unavailable(message: "the \(version) toolchain at \(toolchain) has no swift-format"))
        }
        return .success(
            Resolution(
                executablePath: path,
                origin: "Swift \(version) toolchain, from .swift-version via swiftly",
                fallbackReason: nil,
            ))
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    @Sendable
    private static func runProcess(
        _ command: [String],
        currentDirectory: String,
    ) -> (exitCode: Int32, output: String)? {
        guard let executable = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting, so that output larger than the pipe buffer cannot block the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
