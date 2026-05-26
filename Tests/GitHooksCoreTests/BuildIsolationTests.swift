import GitHooksCore
import Testing

struct BuildIsolationTests {
    @Test
    func `injects derivedDataPath for xcodebuild`() {
        let command = [
            "xcodebuild", "test",
            "-project", "Foo.xcodeproj",
            "-scheme", "FooTests",
            "-destination", "platform=iOS Simulator,name=iPhone 17 Pro",
        ]
        let augmented = BuildIsolation.inject(into: command, scratchPath: "/tmp/scratch-abc")
        let derivedIdx = try? #require(augmented.firstIndex(of: "-derivedDataPath"))
        let pathIdx = derivedIdx.map { augmented.index(after: $0) }
        #expect(pathIdx.map { augmented[$0] } == "/tmp/scratch-abc")
    }

    @Test
    func `injects scratch-path for swift`() {
        let command = ["swift", "test", "--package-path", "/repo"]
        let augmented = BuildIsolation.inject(into: command, scratchPath: "/tmp/scratch-xyz")
        let scratchIdx = try? #require(augmented.firstIndex(of: "--scratch-path"))
        let pathIdx = scratchIdx.map { augmented.index(after: $0) }
        #expect(pathIdx.map { augmented[$0] } == "/tmp/scratch-xyz")
    }

    @Test
    func `does not double-inject when xcodebuild already has derivedDataPath`() {
        // An explicit -derivedDataPath at the call site wins so users can opt out of isolation.
        let command = ["xcodebuild", "test", "-derivedDataPath", "/custom/path"]
        let augmented = BuildIsolation.inject(into: command, scratchPath: "/tmp/scratch")
        #expect(augmented == command)
    }

    @Test
    func `does not double-inject when swift already has scratch-path`() {
        let command = ["swift", "test", "--scratch-path", "/custom/path"]
        let augmented = BuildIsolation.inject(into: command, scratchPath: "/tmp/scratch")
        #expect(augmented == command)
    }

    @Test
    func `does not double-inject when swift has build-path alias`() {
        let command = ["swift", "test", "--build-path", "/custom/path"]
        let augmented = BuildIsolation.inject(into: command, scratchPath: "/tmp/scratch")
        #expect(augmented == command)
    }

    @Test
    func `passes gradle and other tools through unchanged`() {
        let gradle = ["./gradlew", "test"]
        #expect(BuildIsolation.inject(into: gradle, scratchPath: "/tmp/s") == gradle)

        let unknown = ["some-other-tool", "build"]
        #expect(BuildIsolation.inject(into: unknown, scratchPath: "/tmp/s") == unknown)
    }

    @Test
    func `passes empty command through unchanged`() {
        #expect(BuildIsolation.inject(into: [], scratchPath: "/tmp/s") == [])
    }
}
