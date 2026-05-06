import Foundation
import GitHooksCore
import Testing

struct TestTargetResolverTests {
    @Test
    func `find closest module with package swift`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App"),
            withIntermediateDirectories: true,
        )

        let module = TestTargetResolver.findClosestModule(
            forFile: "Sources/App/Main.swift",
            repoRoot: root.path,
            platform: .ios,
        )

        #expect(module == ".")
    }

    @Test
    func `find closest module with nested package swift`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        let moduleDir = root.appendingPathComponent("Packages/MyLib")
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleDir.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: moduleDir.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let module = TestTargetResolver.findClosestModule(
            forFile: "Packages/MyLib/Sources/Foo.swift",
            repoRoot: root.path,
            platform: .ios,
        )

        #expect(module == "Packages/MyLib")
    }

    @Test
    func `find closest module with gradle build`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        let appDir = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: appDir.appendingPathComponent("build.gradle.kts").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: appDir.appendingPathComponent("src/main/kotlin"),
            withIntermediateDirectories: true,
        )

        let module = TestTargetResolver.findClosestModule(
            forFile: "app/src/main/kotlin/App.kt",
            repoRoot: root.path,
            platform: .android,
        )

        #expect(module == "app")
    }

    @Test
    func `find closest module returns nil when no marker found`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true,
        )

        let module = TestTargetResolver.findClosestModule(
            forFile: "src/Foo.swift",
            repoRoot: root.path,
            platform: .ios,
        )

        #expect(module == nil)
    }

    @Test
    func `detect modules deduplicates`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let modules = TestTargetResolver.detectModules(
            changedFiles: ["Sources/A.swift", "Sources/B.swift"],
            repoRoot: root.path,
            platform: .ios,
        )

        #expect(modules.count == 1)
    }

    @Test
    func `detect modules multiple modules with correct paths`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        let moduleA = root.appendingPathComponent("ModuleA")
        try FileManager.default.createDirectory(at: moduleA, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleA.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: moduleA.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let moduleB = root.appendingPathComponent("ModuleB")
        try FileManager.default.createDirectory(at: moduleB, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleB.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: moduleB.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let modules = TestTargetResolver.detectModules(
            changedFiles: ["ModuleA/Sources/A.swift", "ModuleB/Sources/B.swift"],
            repoRoot: root.path,
            platform: .ios,
        )

        #expect(modules.count == 2)

        let modA = try #require(modules.first { $0.name == "ModuleA" })
        #expect(modA.testCommand.contains(moduleA.path))
        #expect(modA.path == "ModuleA")

        let modB = try #require(modules.first { $0.name == "ModuleB" })
        #expect(modB.testCommand.contains(moduleB.path))
        #expect(modB.path == "ModuleB")
    }

    @Test
    func `detect modules includes both test and build commands`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let modules = TestTargetResolver.detectModules(
            changedFiles: ["Sources/A.swift"],
            repoRoot: root.path,
            platform: .ios,
        )

        let module = try #require(modules.first)
        #expect(module.testCommand.contains("test"))
        #expect(module.buildCommand.contains("build"))
    }

    @Test
    func `build test command for SPM package`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: nil,
        )

        let command = TestTargetResolver.buildTestCommand(modulePath: root.path, repoRoot: root.path)

        #expect(command.first == "swift")
        #expect(command.contains("test"))
        #expect(command.contains("--package-path"))
        #expect(command.contains("--scratch-path"))
    }

    @Test
    func `build test command for gradle module`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("build.gradle.kts").path,
            contents: nil,
        )

        let command = TestTargetResolver.buildTestCommand(modulePath: root.path, repoRoot: root.path)

        #expect(command.first == "gradle")
        #expect(command.contains("test"))
        #expect(command.contains(where: { $0.contains("org.gradle.project.buildDir") }))
    }

    @Test
    func `build build command for SPM package`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: nil,
        )

        let command = TestTargetResolver.buildBuildCommand(modulePath: root.path, repoRoot: root.path)

        #expect(command.first == "swift")
        #expect(command.contains("build"))
        #expect(command.contains("--scratch-path"))
    }

    @Test
    func `build commands use isolated build directories`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: nil,
        )

        let testCmd = TestTargetResolver.buildTestCommand(modulePath: root.path, repoRoot: root.path)
        let buildCmd = TestTargetResolver.buildBuildCommand(modulePath: root.path, repoRoot: root.path)

        let testScratchIdx = testCmd.firstIndex(of: "--scratch-path")
        let buildScratchIdx = buildCmd.firstIndex(of: "--scratch-path")

        let testScratch = try #require(testScratchIdx.map { testCmd[testCmd.index(after: $0)] })
        let buildScratch = try #require(buildScratchIdx.map { buildCmd[buildCmd.index(after: $0)] })

        #expect(testScratch.contains("project-hooks-build"))
        #expect(buildScratch.contains("project-hooks-build"))
    }

    @Test
    func `build test command returns empty when no marker found`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        let command = TestTargetResolver.buildTestCommand(modulePath: root.path, repoRoot: root.path)

        #expect(command.isEmpty)
    }

    @Test
    func `gradle falls back to gradle when no wrapper in tree`() throws {
        let root = try makeTempDir(prefix: "target")
        defer { try? FileManager.default.removeItem(at: root) }

        let appDir = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: appDir.appendingPathComponent("build.gradle.kts").path,
            contents: nil,
        )

        let command = TestTargetResolver.buildTestCommand(modulePath: appDir.path, repoRoot: root.path)
        #expect(command.first == "gradle")
    }
}
