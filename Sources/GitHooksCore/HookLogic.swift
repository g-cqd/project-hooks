import Foundation

public struct GitPushUpdate: Equatable {
    public let localRef: String
    public let localSHA: String
    public let remoteRef: String
    public let remoteSHA: String

    public init(localRef: String, localSHA: String, remoteRef: String, remoteSHA: String) {
        self.localRef = localRef
        self.localSHA = localSHA
        self.remoteRef = remoteRef
        self.remoteSHA = remoteSHA
    }

    public var isTagUpdate: Bool {
        localRef.hasPrefix("refs/tags/")
    }

    public var isDeletion: Bool {
        HookLogic.isZeroSHA(localSHA)
    }

    public var isNewRemoteRef: Bool {
        HookLogic.isZeroSHA(remoteSHA)
    }
}

public enum HookLogic {
    public struct BundleResolution {
        public let bundles: [String]
        public let loadedFromXCTestPlan: Bool
        public let xctestplanPath: String
    }

    // MARK: - Push update parsing

    public static func parsePushUpdates(from stdin: String) -> [GitPushUpdate] {
        stdin
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4 else { return nil }
                return GitPushUpdate(
                    localRef: String(parts[0]),
                    localSHA: String(parts[1]),
                    remoteRef: String(parts[2]),
                    remoteSHA: String(parts[3]),
                )
            }
    }

    // MARK: - SHA validation

    public static func isZeroSHA(_ sha: String) -> Bool {
        !sha.isEmpty && sha.allSatisfy { $0 == "0" }
    }

    public static func isValidGitSHA(_ sha: String) -> Bool {
        guard sha.count == 40 else { return false }
        return sha.allSatisfy(\.isHexDigit)
    }

    public static func shouldSkipUpdate(_ update: GitPushUpdate) -> Bool {
        update.isTagUpdate || update.isDeletion
    }

    public static func validateUpdateSHAs(_ update: GitPushUpdate) -> String? {
        if !isValidGitSHA(update.localSHA), !isZeroSHA(update.localSHA) {
            return "Invalid local SHA: \(update.localSHA)"
        }
        if !isValidGitSHA(update.remoteSHA), !isZeroSHA(update.remoteSHA) {
            return "Invalid remote SHA: \(update.remoteSHA)"
        }
        return nil
    }

    // MARK: - XCTestPlan bundle resolution

    public static func parseBundles(fromXCTestPlanData data: Data) -> [String]? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let testTargets = json["testTargets"] as? [[String: Any]]
        else {
            return nil
        }

        var bundles: [String] = []
        var seen = Set<String>()

        for testTarget in testTargets {
            guard let target = testTarget["target"] as? [String: Any] else { continue }

            let name = target["name"] as? String
            let identifier = target["identifier"] as? String

            let candidate: String? = if let name, !name.isEmpty {
                name
            } else if let identifier, identifier.hasSuffix("Tests") {
                identifier
            } else {
                nil
            }

            guard let candidate else { continue }
            if seen.insert(candidate).inserted {
                bundles.append(candidate)
            }
        }

        return bundles.isEmpty ? nil : bundles
    }

    public static func bundlesFromXCTestPlan(atFilePath filePath: String) -> [String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        return parseBundles(fromXCTestPlanData: data)
    }

    public static func resolveAvailableBundles(
        repoRoot: String,
        testPlanRelativePath: String,
    ) -> BundleResolution {
        let xctestplanPath = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(testPlanRelativePath)
            .path

        if let bundles = bundlesFromXCTestPlan(atFilePath: xctestplanPath) {
            return BundleResolution(bundles: bundles, loadedFromXCTestPlan: true, xctestplanPath: xctestplanPath)
        }

        return BundleResolution(bundles: [], loadedFromXCTestPlan: false, xctestplanPath: xctestplanPath)
    }

    /// Select which test bundles to run based on changed files.
    /// Maps each file's top-level directory to a bundle name (appending "Tests" if needed).
    public static func selectBundles(changedFiles: [String], availableBundles: [String]) -> [String] {
        let available = Set(availableBundles)
        var selected = Set<String>()

        for file in Set(changedFiles) {
            guard let rootComponent = file.split(separator: "/", maxSplits: 1).first.map(String.init) else {
                continue
            }

            if available.contains(rootComponent) {
                selected.insert(rootComponent)
            } else {
                let inferred = "\(rootComponent)Tests"
                if available.contains(inferred) {
                    selected.insert(inferred)
                }
            }
        }

        return availableBundles.filter { selected.contains($0) }
    }
}
