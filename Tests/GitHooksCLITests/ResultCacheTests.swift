import Foundation
import Testing

@testable import GitHooksCLI

struct ResultCacheTests {
    private static let base = (
        tree: "tree-1", module: "Packages/Core", command: ["swift", "test", "--package-path", "/wt/Packages/Core"],
        tools: "Swift 6.4", environment: ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"],
    )

    private func key(
        tree: String = base.tree,
        module: String = base.module,
        command: [String] = base.command,
        root: String = "/wt",
        tools: String = base.tools,
        environment: [String: String] = base.environment,
    ) -> String {
        ResultCache.key(
            kind: "test", tree: tree, module: module, command: command, root: root, tools: tools,
            environment: environment,
        )
    }

    @Test
    func `the checkout's location and unrelated variables do not change the key`() {
        let moved = key(command: ["swift", "test", "--package-path", "/elsewhere/Packages/Core"], root: "/elsewhere")
        let unrelated = key(environment: Self.base.environment.merging(["TERM": "xterm"]) { $1 })

        #expect(moved == key())
        #expect(unrelated == key())
    }

    @Test
    func `the tree, the module, the command, the tools and the toolchain variables change the key`() {
        let variants = [
            key(tree: "tree-2"),
            key(module: "Packages/UI"),
            key(command: Self.base.command + ["--filter", "Fast"]),
            key(tools: "Swift 6.3"),
            key(environment: ["DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"]),
            key(environment: Self.base.environment.merging(["JAVA_HOME": "/jdk"]) { $1 }),
        ]

        #expect(Set(variants + [key()]).count == variants.count + 1)
    }

    @Test
    func `recorded passes are found, and the least recently used go beyond capacity`() throws {
        var cache = ResultCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID().uuidString)")
                .path,
            isEnabled: true,
        )
        cache.capacity = 2
        defer { try? FileManager.default.removeItem(atPath: cache.directory) }

        cache.recordPass("first")
        cache.recordPass("second")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: "\(cache.directory)/first",
        )
        cache.recordPass("third")

        #expect(!cache.hasPassed("first"))
        #expect(cache.hasPassed("second"))
        #expect(cache.hasPassed("third"))
    }

    @Test
    func `a disabled cache finds nothing`() {
        let cache = ResultCache(directory: "/nonexistent", isEnabled: false)
        #expect(!cache.hasPassed("anything"))
    }
}
