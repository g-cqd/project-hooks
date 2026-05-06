import Foundation
import GitHooksCore
import Testing

struct ProjectDetectorTests {
    @Test
    func `detect platform from files with swift files`() {
        let files = ["Sources/App/Main.swift", "Tests/AppTests/MainTests.swift"]
        #expect(ProjectDetector.detectPlatformFromFiles(files) == .ios)
    }

    @Test
    func `detect platform from files with kotlin files`() {
        let files = ["app/src/main/kotlin/App.kt", "build.gradle.kts"]
        #expect(ProjectDetector.detectPlatformFromFiles(files) == .android)
    }

    @Test
    func `detect platform from files with java files`() {
        let files = ["app/src/main/java/App.java"]
        #expect(ProjectDetector.detectPlatformFromFiles(files) == .android)
    }

    @Test
    func `detect platform from files with mixed files`() {
        let files = ["Sources/App/Main.swift", "app/src/main/kotlin/App.kt"]
        #expect(ProjectDetector.detectPlatformFromFiles(files) == .mixed)
    }

    @Test
    func `detect platform from files with unknown files`() {
        let files = ["README.md", "docs/architecture.md"]
        #expect(ProjectDetector.detectPlatformFromFiles(files) == .unknown)
    }

    @Test
    func `detect platform from files empty`() {
        #expect(ProjectDetector.detectPlatformFromFiles([]) == .unknown)
    }

    @Test
    func `detect platform from repo with package swift`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("Package.swift").path,
            contents: nil,
        )

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .ios)
    }

    @Test
    func `detect platform from repo with xcodeproj`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true,
        )

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .ios)
    }

    @Test
    func `detect platform from repo with xcworkspace`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("App.xcworkspace"),
            withIntermediateDirectories: true,
        )

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .ios)
    }

    @Test
    func `detect platform from repo with gradle build`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("build.gradle.kts").path,
            contents: nil,
        )

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .android)
    }

    @Test
    func `detect platform from repo with settings gradle`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("settings.gradle.kts").path,
            contents: nil,
        )

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .android)
    }

    @Test
    func `detect platform from repo with both markers`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        FileManager.default.createFile(
            atPath: tmpDir.appendingPathComponent("build.gradle").path,
            contents: nil,
        )

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .mixed)
    }

    @Test
    func `detect platform from empty repo`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(ProjectDetector.detectPlatform(repoRoot: tmpDir.path) == .unknown)
    }
}
