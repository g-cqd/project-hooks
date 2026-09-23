import Foundation
import GitHooksCore

/// Build directories that later runs reuse, one per repository and module, bounded in total size.
///
/// Reusing a module's directory keeps resolved dependencies and their build products, so a push rebuilds only what
/// changed. When the entries together exceed the limit, the least recently used ones are removed, except those that a
/// run is using.
struct BuildCache {
    /// The default limit, in gigabytes, when `GITHOOKS_BUILD_CACHE_LIMIT_GB` is not set.
    static let defaultLimitGigabytes = 10.0

    let directory: String
    let limitBytes: Int64

    /// One module's build directory.
    struct Entry {
        let key: String
        let path: String
        let lockPath: String
        /// Holds the entry's size in bytes.
        ///
        /// Its modification date is the entry's last use.
        let usagePath: String
    }

    /// The cache in `HookCache.root`, limited by `GITHOOKS_BUILD_CACHE_LIMIT_GB`.
    static func standard() -> BuildCache {
        let configured = ProcessInfo.processInfo.environment["GITHOOKS_BUILD_CACHE_LIMIT_GB"].flatMap(Double.init)
        let gigabytes = configured.flatMap { $0 >= 0 ? $0 : nil } ?? defaultLimitGigabytes
        return BuildCache(directory: HookCache.root + "/builds", limitBytes: Int64(gigabytes * 1_073_741_824))
    }

    /// The entry for `module`, a module path relative to the repository root, of the repository `repositoryKey` names.
    func entry(repositoryKey: String, module: String) -> Entry {
        let moduleName = module == "." ? "root" : HookCache.sanitized(URL(fileURLWithPath: module).lastPathComponent)
        let key = "\(repositoryKey)-\(moduleName)-\(HookCache.digest([repositoryKey, module]).prefix(12))"
        let path = "\(directory)/\(key)"
        return Entry(key: key, path: path, lockPath: "\(path).lock", usagePath: "\(path).usage")
    }

    /// Run `body` with the entry locked against eviction, then record its size and evict entries beyond the limit,
    /// whether or not `body` throws.
    func use<Value>(_ entry: Entry, _ body: () throws -> Value) throws -> Value {
        let lock = try FileLock(path: entry.lockPath)
        let outcome: Result<Value, any Error>
        do {
            try FileManager.default.createDirectory(atPath: entry.path, withIntermediateDirectories: true)
            outcome = try .success(body())
        } catch {
            outcome = .failure(error)
        }
        recordUsage(of: entry)
        _ = consume lock
        evict(keeping: entry.key)
        return try outcome.get()
    }

    private func recordUsage(of entry: Entry) {
        let size = Self.allocatedSize(of: entry.path)
        do {
            try String(size).write(toFile: entry.usagePath, atomically: true, encoding: .utf8)
        } catch {
            printWarn("Could not record the size of the build cache entry \(entry.key): \(error)")
        }
    }

    /// Remove the least recently used entries, other than `current` and those in use, until the cache fits its limit.
    func evict(keeping current: String) {
        struct Usage {
            let key: String
            let bytes: Int64
            let lastUse: Date
        }

        let fileManager = FileManager.default
        let usages = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".usage") }
            .compactMap { name -> Usage? in
                let path = "\(directory)/\(name)"
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                    let bytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                    let lastUse = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { return nil }
                return Usage(key: String(name.dropLast(".usage".count)), bytes: bytes, lastUse: lastUse)
            }

        var total = usages.reduce(0) { $0 + $1.bytes }
        for usage in usages.sorted(by: { $0.lastUse < $1.lastUse }) where total > limitBytes && usage.key != current {
            // An entry that another run holds is in use: keep it.
            guard let lock = FileLock(ifAvailableAt: "\(directory)/\(usage.key).lock") else { continue }
            do {
                try fileManager.removeItem(atPath: "\(directory)/\(usage.key)")
                try fileManager.removeItem(atPath: "\(directory)/\(usage.key).usage")
                total -= usage.bytes
                printInfo("Build cache: removed \(usage.key), unused since \(usage.lastUse.formatted()).")
            } catch {
                printWarn("Could not remove the build cache entry \(usage.key): \(error)")
            }
            _ = consume lock
        }
    }

    /// The disk space that the files under `path` take.
    /// - Complexity: O(n) in the number of files under `path`.
    static func allocatedSize(of path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: keys,
            )
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
