import Foundation

/// Matches files against glob-like patterns (simple suffix/prefix matching).
public enum FileGlobMatcher {
    /// Check if a file path matches any of the given glob patterns.
    ///
    /// Supports: `*.ext`, `path/*`, `*.lproj/*`, exact matches.
    public static func matches(_ filePath: String, patterns: [String]) -> Bool {
        patterns.contains { matchesSingle(filePath, pattern: $0) }
    }

    private static func matchesSingle(_ filePath: String, pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)

        // No wildcard — exact or filename match
        if parts.count == 1 {
            return filePath == pattern || filePath.hasSuffix("/\(pattern)")
        }

        // Wildcard: all non-empty parts must appear in order in the file path
        var searchStart = filePath.startIndex
        for (index, part) in parts.enumerated() where !part.isEmpty {
            let haystack = filePath[searchStart...]
            if index == 0 {
                guard haystack.hasPrefix(part) else { return false }
                searchStart = filePath.index(searchStart, offsetBy: part.count)
            } else if index == parts.count - 1 {
                guard haystack.hasSuffix(part) else { return false }
            } else {
                guard let range = haystack.range(of: part) else { return false }
                searchStart = range.upperBound
            }
        }
        return true
    }

    /// Filter files that match any of the patterns.
    public static func filter(_ files: [String], matching patterns: [String]) -> [String] {
        files.filter { matches($0, patterns: patterns) }
    }
}

/// Orders custom tasks respecting `after` dependencies.
public enum TaskDependencyResolver {
    /// Sort tasks so that tasks with `after` dependencies come after their dependency.
    ///
    /// Returns nil if there's a circular dependency.
    public static func resolve(_ tasks: [HooksConfig.CustomTask]) -> [HooksConfig.CustomTask]? {
        var resolved: [HooksConfig.CustomTask] = []
        var pending = tasks
        var iterations = 0
        let maxIterations = tasks.count * tasks.count + 1

        while !pending.isEmpty {
            iterations += 1
            if iterations > maxIterations { return nil }

            let resolvedNames = Set(resolved.map(\.name))
            var progressed = false

            pending.removeAll { task in
                if let dep = task.after, !resolvedNames.contains(dep) {
                    return false
                }
                resolved.append(task)
                progressed = true
                return true
            }

            if !progressed { return nil }
        }

        return resolved
    }
}
