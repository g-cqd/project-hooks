import Foundation
import GitHooksCore
import Testing

struct ConfigResolverTests {
    @Test
    func `find closest config at repo root`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App"),
            withIntermediateDirectories: true,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "Sources/App/Main.swift",
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(config == root.appendingPathComponent(".swiftlint.yml").path)
    }

    @Test
    func `find closest config in subdirectory`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )
        let moduleDir = root.appendingPathComponent("ModuleA")
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleDir.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: moduleDir.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "ModuleA/Sources/Foo.swift",
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(config == moduleDir.appendingPathComponent(".swiftlint.yml").path)
    }

    @Test
    func `find closest config returns nil when not found`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "Sources/Foo.swift",
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(config == nil)
    }

    @Test
    func `find closest config tries multiple candidates`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".swiftlint.yaml").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "Sources/Foo.swift",
            repoRoot: root.path,
            candidates: [".swiftlint.yml", ".swiftlint.yaml"],
        )

        #expect(config == root.appendingPathComponent(".swiftlint.yaml").path)
    }

    @Test
    func `find closest config for file at repo root`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "Package.swift",
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(config == root.appendingPathComponent(".swiftlint.yml").path)
    }

    @Test
    func `find closest config with empty candidates`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        let config = ConfigResolver.findClosestConfig(
            forFile: "Sources/Foo.swift",
            repoRoot: root.path,
            candidates: [],
        )

        #expect(config == nil)
    }

    @Test
    func `find closest config with multi component candidate`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        let configDir = root.appendingPathComponent("config/detekt")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: configDir.appendingPathComponent("detekt.yml").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("app/src"),
            withIntermediateDirectories: true,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "app/src/Main.kt",
            repoRoot: root.path,
            candidates: ["config/detekt/detekt.yml"],
        )

        #expect(config != nil)
        #expect(config?.hasSuffix("config/detekt/detekt.yml") == true)
    }

    @Test
    func `find closest config deeply nested`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a/b/c/d/e"),
            withIntermediateDirectories: true,
        )

        let config = ConfigResolver.findClosestConfig(
            forFile: "a/b/c/d/e/Deep.swift",
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(config == root.appendingPathComponent(".swiftlint.yml").path)
    }

    @Test
    func `group files by config separates files by closest config`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )
        let moduleA = root.appendingPathComponent("ModuleA")
        try FileManager.default.createDirectory(at: moduleA, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleA.appendingPathComponent(".swiftlint.yml").path,
            contents: nil,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: moduleA.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let files = [
            "Sources/Root.swift",
            "ModuleA/Sources/Foo.swift",
            "ModuleA/Sources/Bar.swift",
        ]

        let groups = ConfigResolver.groupFilesByConfig(
            files: files,
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(groups.count == 2)

        let moduleAGroup = groups.first { $0.config?.contains("ModuleA") == true }
        let rootGroup = groups.first { $0.config?.contains("ModuleA") != true }

        #expect(moduleAGroup?.files.sorted() == ["ModuleA/Sources/Bar.swift", "ModuleA/Sources/Foo.swift"])
        #expect(rootGroup?.files == ["Sources/Root.swift"])
    }

    @Test
    func `group files by config puts no config files in nil group`() throws {
        let root = try makeTempDir(prefix: "config")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true,
        )

        let groups = ConfigResolver.groupFilesByConfig(
            files: ["Sources/Foo.swift"],
            repoRoot: root.path,
            candidates: [".swiftlint.yml"],
        )

        #expect(groups.count == 1)
        #expect(groups[0].config == nil)
        #expect(groups[0].files == ["Sources/Foo.swift"])
    }
}
