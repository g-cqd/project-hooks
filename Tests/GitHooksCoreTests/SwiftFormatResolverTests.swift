import GitHooksCore
import Testing

struct SwiftFormatResolverTests {
    private static let repoRoot = "/work/app"
    private static let home = "/Users/me"
    private static let toolchain = "/Users/me/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain"
    private static let xcodeSwiftFormat = "/Applications/Xcode.app/Contents/Developer/usr/bin/swift-format"

    /// A machine with swiftly in Homebrew, the 6.4.0 toolchain, and Xcode.
    private static let machine = Machine(
        files: [:],
        executables: [
            "/opt/homebrew/bin/swiftly", "\(toolchain)/usr/bin/swift-format", xcodeSwiftFormat,
        ],
        commands: [
            "\(repoRoot)$/opt/homebrew/bin/swiftly use --print-location": (0, "\(toolchain)\n"),
            "\(repoRoot)$/usr/bin/xcrun --find swift-format": (0, "\(xcodeSwiftFormat)\n"),
        ],
    )

    @Test
    func `a repository's .swift-version selects its toolchain's swift-format, through swiftly in the repository`() {
        let machine = Self.machine.with(file: "\(Self.repoRoot)/.swift-version", "6.4.0\n")

        let resolution = SwiftFormatResolver.resolve(repoRoot: Self.repoRoot, home: Self.home, probe: machine.probe)

        #expect(resolution?.executablePath == "\(Self.toolchain)/usr/bin/swift-format")
        #expect(resolution?.origin.contains("6.4.0") == true)
        #expect(resolution?.fallbackReason == nil)
    }

    @Test
    func `without .swift-version, Xcode's swift-format is used`() {
        let resolution = SwiftFormatResolver.resolve(
            repoRoot: Self.repoRoot,
            home: Self.home,
            probe: Self.machine.probe,
        )

        #expect(resolution?.executablePath == Self.xcodeSwiftFormat)
        #expect(resolution?.fallbackReason == nil)
    }

    @Test
    func `a toolchain that swiftly has not installed falls back to Xcode, with the reason`() {
        let machine = Self.machine
            .with(file: "\(Self.repoRoot)/.swift-version", "6.1.2\n")
            .with(command: "\(Self.repoRoot)$/opt/homebrew/bin/swiftly use --print-location", exitCode: 1, output: "")

        let resolution = SwiftFormatResolver.resolve(repoRoot: Self.repoRoot, home: Self.home, probe: machine.probe)

        #expect(resolution?.executablePath == Self.xcodeSwiftFormat)
        #expect(resolution?.fallbackReason?.contains("6.1.2") == true)
    }

    @Test
    func `without swiftly, .swift-version falls back to Xcode, with the reason`() {
        let machine = Self.machine
            .with(file: "\(Self.repoRoot)/.swift-version", "6.4.0\n")
            .without(executable: "/opt/homebrew/bin/swiftly")

        let resolution = SwiftFormatResolver.resolve(repoRoot: Self.repoRoot, home: Self.home, probe: machine.probe)

        #expect(resolution?.executablePath == Self.xcodeSwiftFormat)
        #expect(resolution?.fallbackReason?.contains("swiftly is not installed") == true)
    }

    @Test
    func `swiftly in the home directory comes before Homebrew's`() {
        let homeSwiftly = "\(Self.home)/.swiftly/bin/swiftly"
        let machine = Self.machine
            .with(file: "\(Self.repoRoot)/.swift-version", "6.4.0\n")
            .with(executable: homeSwiftly)
            .with(command: "\(Self.repoRoot)$\(homeSwiftly) use --print-location", exitCode: 0, output: "/other\n")
            .with(executable: "/other/usr/bin/swift-format")

        let resolution = SwiftFormatResolver.resolve(repoRoot: Self.repoRoot, home: Self.home, probe: machine.probe)

        #expect(resolution?.executablePath == "/other/usr/bin/swift-format")
    }

    @Test
    func `a toolchain without swift-format falls back to Xcode`() {
        let machine = Self.machine
            .with(file: "\(Self.repoRoot)/.swift-version", "6.4.0\n")
            .without(executable: "\(Self.toolchain)/usr/bin/swift-format")

        let resolution = SwiftFormatResolver.resolve(repoRoot: Self.repoRoot, home: Self.home, probe: machine.probe)

        #expect(resolution?.executablePath == Self.xcodeSwiftFormat)
        #expect(resolution?.fallbackReason?.contains("has no swift-format") == true)
    }

    @Test
    func `no toolchain provides swift-format`() {
        let machine = Self.machine.with(
            command: "\(Self.repoRoot)$/usr/bin/xcrun --find swift-format",
            exitCode: 1,
            output: "",
        )

        #expect(SwiftFormatResolver.resolve(repoRoot: Self.repoRoot, home: Self.home, probe: machine.probe) == nil)
    }
}

/// A fake machine: file contents, executable paths, and command results keyed by "<directory>$<command>".
private struct Machine {
    var files: [String: String]
    var executables: Set<String>
    var commands: [String: (Int32, String)]

    var probe: SwiftFormatResolver.Probe {
        let files = files
        let executables = executables
        let commands = commands
        return SwiftFormatResolver.Probe(
            isExecutable: { executables.contains($0) },
            readFile: { files[$0] },
            run: { command, directory in
                commands["\(directory)$\(command.joined(separator: " "))"].map { (exitCode: $0.0, output: $0.1) }
            },
        )
    }

    func with(file path: String, _ contents: String) -> Machine {
        var copy = self
        copy.files[path] = contents
        return copy
    }

    func with(executable path: String) -> Machine {
        var copy = self
        copy.executables.insert(path)
        return copy
    }

    func without(executable path: String) -> Machine {
        var copy = self
        copy.executables.remove(path)
        return copy
    }

    func with(command key: String, exitCode: Int32, output: String) -> Machine {
        var copy = self
        copy.commands[key] = (exitCode, output)
        return copy
    }
}
