import Foundation
import Testing

@testable import GitHooksCLI

struct BuildCacheTests {
    @Test
    func `each repository and module has one stable entry`() {
        let cache = BuildCache(directory: "/cache/builds", limitBytes: 0)

        let core = cache.entry(repositoryKey: "app-0123", module: "Packages/Core")
        let again = cache.entry(repositoryKey: "app-0123", module: "Packages/Core")
        let other = cache.entry(repositoryKey: "app-0123", module: "Packages/UI")
        let clone = cache.entry(repositoryKey: "app-4567", module: "Packages/Core")
        let root = cache.entry(repositoryKey: "app-0123", module: ".")

        #expect(core.path == again.path)
        #expect(Set([core.path, other.path, clone.path, root.path]).count == 4)
        #expect(core.key.hasPrefix("app-0123-Core-"))
        #expect(root.key.hasPrefix("app-0123-root-"))
    }

    @Test
    func `the least recently used entries go until the cache fits its limit`() throws {
        let cache = try makeCache(limitBytes: 700, entries: [("old", 400, 1), ("middle", 300, 2), ("new", 300, 3)])
        defer { try? FileManager.default.removeItem(atPath: cache.directory) }

        cache.evict(keeping: "new")

        #expect(try remainingEntries(in: cache) == ["middle", "new"])
    }

    @Test
    func `an entry that another run holds is kept`() throws {
        let cache = try makeCache(limitBytes: 700, entries: [("old", 400, 1), ("middle", 300, 2), ("new", 300, 3)])
        defer { try? FileManager.default.removeItem(atPath: cache.directory) }
        let held = try FileLock(path: "\(cache.directory)/old.lock")

        cache.evict(keeping: "new")
        _ = consume held

        #expect(try remainingEntries(in: cache) == ["new", "old"])
    }

    @Test
    func `the entry in use stays even when it alone exceeds the limit`() throws {
        let cache = try makeCache(limitBytes: 100, entries: [("old", 300, 1), ("current", 500, 2)])
        defer { try? FileManager.default.removeItem(atPath: cache.directory) }

        cache.evict(keeping: "current")

        #expect(try remainingEntries(in: cache) == ["current"])
    }

    @Test
    func `using an entry records its size`() throws {
        let cache = try makeCache(limitBytes: 1 << 40, entries: [])
        defer { try? FileManager.default.removeItem(atPath: cache.directory) }
        let entry = cache.entry(repositoryKey: "app-0123", module: ".")

        try cache.use(entry) {
            try Data(count: 10000).write(to: URL(fileURLWithPath: "\(entry.path)/product"))
        }

        let recorded = try #require(Int64(String(contentsOfFile: entry.usagePath, encoding: .utf8)))
        #expect(recorded >= 10000)
    }

    /// A cache whose entries have the given sizes, in bytes, and last uses, in seconds since the reference date.
    private func makeCache(limitBytes: Int64, entries: [(String, Int64, TimeInterval)]) throws -> BuildCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-cache-\(UUID().uuidString)").path
        for (key, bytes, lastUse) in entries {
            try FileManager.default.createDirectory(atPath: "\(directory)/\(key)", withIntermediateDirectories: true)
            try String(bytes).write(toFile: "\(directory)/\(key).usage", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: lastUse)],
                ofItemAtPath: "\(directory)/\(key).usage",
            )
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return BuildCache(directory: directory, limitBytes: limitBytes)
    }

    private func remainingEntries(in cache: BuildCache) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: cache.directory)
            .filter { $0.hasSuffix(".usage") }
            .map { String($0.dropLast(".usage".count)) }
            .sorted()
    }
}
