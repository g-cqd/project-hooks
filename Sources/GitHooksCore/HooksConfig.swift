import Darwin
import Foundation
import Yams

/// Configuration loaded from `.project-hooks.yml` in the repo root.
/// When absent, all fields default to nil/empty — the hooks engine runs
/// with auto-detection only (linting + test targeting, no custom tasks).
public struct HooksConfig: Equatable {
    public var preCommit: PreCommitConfig
    public var prePush: PrePushConfig

    public init(
        preCommit: PreCommitConfig = PreCommitConfig(),
        prePush: PrePushConfig = PrePushConfig(),
    ) {
        self.preCommit = preCommit
        self.prePush = prePush
    }

    // MARK: - Pre-commit

    public struct PreCommitConfig: Equatable {
        public var tasks: [CustomTask]

        public init(tasks: [CustomTask] = []) {
            self.tasks = tasks
        }
    }

    // MARK: - Pre-push

    public struct PrePushConfig: Equatable {
        public var commitMessage: CommitMessageConfig?
        public var branchName: BranchNameConfig?
        public var workScope: WorkScopeConfig?
        public var rejectTrailers: [String]
        public var testOverride: TestOverride?
        public var prSize: PRSizeConfig?
        public var tasks: [CustomTask]

        public init(
            commitMessage: CommitMessageConfig? = nil,
            branchName: BranchNameConfig? = nil,
            workScope: WorkScopeConfig? = nil,
            rejectTrailers: [String] = [],
            testOverride: TestOverride? = nil,
            prSize: PRSizeConfig? = nil,
            tasks: [CustomTask] = [],
        ) {
            self.commitMessage = commitMessage
            self.branchName = branchName
            self.workScope = workScope
            self.rejectTrailers = rejectTrailers
            self.testOverride = testOverride
            self.prSize = prSize
            self.tasks = tasks
        }
    }

    // MARK: - Custom task

    public struct CustomTask: Equatable {
        public let name: String
        public let run: String
        public let onFiles: [String]?
        public let restage: RestageConfig?
        public let after: String?
        public let timeout: Int?

        public init(
            name: String,
            run: String,
            onFiles: [String]? = nil,
            restage: RestageConfig? = nil,
            after: String? = nil,
            timeout: Int? = nil,
        ) {
            self.name = name
            self.run = run
            self.onFiles = onFiles
            self.restage = restage
            self.after = after
            self.timeout = timeout
        }
    }

    public enum RestageConfig: Equatable {
        /// Re-stage the files that matched `onFiles`
        case matchedFiles
        /// Re-stage specific paths
        case paths([String])
    }

    // MARK: - Commit message

    public struct CommitMessageConfig: Equatable {
        public let pattern: String
        public let error: String
        /// Optional baseline ref (e.g. "origin/develop"). When set, commit-message validation
        /// only checks commits in the push range that are NOT reachable from `base`. This
        /// avoids re-validating upstream commits that a rebased branch inherits but did not author.
        public let base: String?

        public init(pattern: String, error: String, base: String? = nil) {
            self.pattern = pattern
            self.error = error
            self.base = base
        }
    }

    // MARK: - Branch name

    public struct BranchNameConfig: Equatable {
        public let pattern: String
        public let error: String
        public let skip: [String]

        public init(pattern: String, error: String, skip: [String] = []) {
            self.pattern = pattern
            self.error = error
            self.skip = skip
        }
    }

    // MARK: - Work scope

    public enum WalkStrategy: String, Equatable {
        /// Walk every commit in the range (git default).
        case `default`
        /// Walk only first-parent commits (skips commits brought in by merges).
        case firstParent = "first-parent"
    }

    public enum MismatchAction: String, Equatable {
        case skip
        case warn
        case fail
    }

    public struct CommitFilterConfig: Equatable {
        public let branchPattern: String
        public let commitPattern: String
        public let onMismatch: MismatchAction
        public let includeMerges: Bool

        public init(
            branchPattern: String,
            commitPattern: String,
            onMismatch: MismatchAction = .warn,
            includeMerges: Bool = true,
        ) {
            self.branchPattern = branchPattern
            self.commitPattern = commitPattern
            self.onMismatch = onMismatch
            self.includeMerges = includeMerges
        }
    }

    public struct WorkScopeConfig: Equatable {
        /// Integration branch used as the baseline (e.g. "origin/develop").
        /// The push range becomes merge-base(HEAD, base)..HEAD.
        public let base: String
        public let walk: WalkStrategy
        public let commitFilter: CommitFilterConfig?

        public init(
            base: String,
            walk: WalkStrategy = .firstParent,
            commitFilter: CommitFilterConfig? = nil,
        ) {
            self.base = base
            self.walk = walk
            self.commitFilter = commitFilter
        }
    }

    // MARK: - PR size metric

    /// Threshold and weight configuration for the PR-size cognitive-load check.
    /// See `PRSizeMetric` for the formula and the empirical research the defaults
    /// are calibrated against.
    public struct PRSizeConfig: Equatable {
        public enum Mode: String, Equatable, Sendable {
            /// Print the report and continue. Default.
            case warn
            /// Print the report and block the push.
            case fail
        }

        /// Built-in test-file patterns used when `testPatterns` is nil (i.e. the
        /// user didn't specify the key). An explicit empty list disables test
        /// classification entirely — every changed file then counts as production.
        public static let defaultTestPatterns: [String] = [
            "Tests/*",
            "*/Tests/*",
            "test/*",
            "*/test/*",
            "src/test/*",
            "*/src/test/*",
            "__tests__/*",
            "*/__tests__/*",
            "*Tests.swift",
            "*Test.swift",
            "*Spec.swift",
            "*Tests.kt",
            "*Test.kt",
            "*Spec.kt",
            "*Tests.java",
            "*Test.java",
        ]

        public let mode: Mode
        public let maxAdditions: Int?
        public let maxDeletions: Int?
        public let maxFiles: Int?
        public let maxScatter: Double?
        public let maxCognitiveScore: Double?
        public let volumeWeight: Double
        public let scatterWeight: Double
        public let testCompensation: Double
        public let exclude: [String]
        /// When nil, `defaultTestPatterns` is used. An explicit empty list keeps
        /// all files as production code (useful for repos with no test directory).
        public let testPatterns: [String]?

        public init(
            mode: Mode = .warn,
            maxAdditions: Int? = 800,
            maxDeletions: Int? = 800,
            maxFiles: Int? = 30,
            maxScatter: Double? = nil,
            maxCognitiveScore: Double? = 18.0,
            volumeWeight: Double = 1.0,
            scatterWeight: Double = 1.0,
            testCompensation: Double = 0.25,
            exclude: [String] = [],
            testPatterns: [String]? = nil,
        ) {
            self.mode = mode
            self.maxAdditions = maxAdditions
            self.maxDeletions = maxDeletions
            self.maxFiles = maxFiles
            self.maxScatter = maxScatter
            self.maxCognitiveScore = maxCognitiveScore
            self.volumeWeight = volumeWeight
            self.scatterWeight = scatterWeight
            self.testCompensation = testCompensation
            self.exclude = exclude
            self.testPatterns = testPatterns
        }

        public var effectiveTestPatterns: [String] {
            testPatterns ?? Self.defaultTestPatterns
        }
    }

    // MARK: - Test override

    public enum TestRunnerType: String {
        case xcodebuild
        case swift
        case gradle
    }

    public struct TestOverride: Equatable {
        public let type: TestRunnerType
        public let project: String?
        public let scheme: String?
        public let testPlan: String?
        public let destination: String?
        public let broadImpactPaths: [String]?
        /// gradle-only: a specific gradle task (or task path) to run. When nil, runs `test`.
        /// Useful to scope away from the full multi-flavor matrix that bare `gradle test` triggers.
        public let task: String?
        /// Free-form arguments appended to the constructed test command, regardless of runner.
        /// Escape hatch for runner-specific flags we don't model directly:
        /// - xcodebuild: e.g. `-skipPackagePluginValidation`, `OTHER_SWIFT_FLAGS=-D SKIP_X`
        /// - gradle: e.g. `--no-daemon`, `-PskipFoo=true`
        /// - swift: e.g. `--filter SomeTests`
        /// Args are passed through verbatim — quoting/escaping is the caller's responsibility.
        public let extraArgs: [String]?

        public init(
            type: TestRunnerType,
            project: String? = nil,
            scheme: String? = nil,
            testPlan: String? = nil,
            destination: String? = nil,
            broadImpactPaths: [String]? = nil,
            task: String? = nil,
            extraArgs: [String]? = nil,
        ) {
            self.type = type
            self.project = project
            self.scheme = scheme
            self.testPlan = testPlan
            self.destination = destination
            self.broadImpactPaths = broadImpactPaths
            self.task = task
            self.extraArgs = extraArgs
        }
    }
}

// MARK: - Config Source

/// Describes where a resolved configuration was loaded from.
public enum ConfigSource: Equatable, Sendable {
    /// Local repo config: `<repoRoot>/.project-hooks.yml`
    case local
    /// XDG config directory: `~/.config/project-hooks/config.yml`
    case xdgConfig
    /// Home directory: `~/.project-hooks.yml`
    case home
}

/// A resolved configuration bundled with its source location.
public struct ResolvedConfig: Equatable {
    public let config: HooksConfig
    public let source: ConfigSource

    public init(config: HooksConfig, source: ConfigSource) {
        self.config = config
        self.source = source
    }

    /// Human-readable description of the config source for CLI output.
    public var sourceDescription: String {
        switch source {
        case .local:
            ".project-hooks.yml"
        case .xdgConfig:
            "~/.config/project-hooks/config.yml"
        case .home:
            "~/.project-hooks.yml"
        }
    }
}

// MARK: - Loading

extension HooksConfig {
    public static let configFileName = ".project-hooks.yml"

    /// Load config from repo root. Returns nil if no config file exists.
    /// Throws if the file exists but is malformed.
    ///
    /// This method checks three locations in precedence order (first match wins):
    /// 1. Local: `<repoRoot>/.project-hooks.yml`
    /// 2. XDG config: `~/.config/project-hooks/config.yml`
    /// 3. Home: `~/.project-hooks.yml`
    public static func load(repoRoot: String) throws -> HooksConfig? {
        try resolve(repoRoot: repoRoot)?.config
    }

    /// Resolve config with source information. Returns nil if no config is found
    /// in any of the checked locations.
    ///
    /// Precedence (first match wins, replace semantics — no merging):
    /// 1. Local: `<repoRoot>/.project-hooks.yml`
    /// 2. XDG config: `~/.config/project-hooks/config.yml`
    /// 3. Home: `~/.project-hooks.yml`
    ///
    /// User-level configs (XDG and home) support two formats:
    /// - **Flat**: standard hook config that applies to all repos
    /// - **Projects-list**: keyed by path/glob patterns under a `projects` key
    public static func resolve(repoRoot: String) throws -> ResolvedConfig? {
        // 1. Local repo config (always flat format)
        let localPath = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(configFileName)
            .path

        if FileManager.default.fileExists(atPath: localPath) {
            let contents = try String(contentsOfFile: localPath, encoding: .utf8)
            let config = try parse(yaml: contents)
            return ResolvedConfig(config: config, source: .local)
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // 2. XDG config directory
        let xdgPath = (homeDir as NSString)
            .appendingPathComponent(".config/project-hooks/config.yml")

        if let config = try loadUserConfig(atPath: xdgPath, repoRoot: repoRoot) {
            return ResolvedConfig(config: config, source: .xdgConfig)
        }

        // 3. Home directory
        let homePath = (homeDir as NSString)
            .appendingPathComponent(configFileName)

        if let config = try loadUserConfig(atPath: homePath, repoRoot: repoRoot) {
            return ResolvedConfig(config: config, source: .home)
        }

        return nil
    }

    /// Load a user-level config file, dynamically detecting flat vs projects-list format.
    /// Returns nil if the file does not exist or if it's a projects-list config with no
    /// matching pattern for the given repo root.
    static func loadUserConfig(atPath path: String, repoRoot: String) throws -> HooksConfig? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        guard let dict = try Yams.load(yaml: contents) as? [String: Any] else {
            return HooksConfig()
        }

        // Detection: if top-level has a "projects" key, it's a projects-list config
        if let projects = dict["projects"] as? [String: Any] {
            return try parseProjectsList(projects, repoRoot: repoRoot)
        }

        // Otherwise it's a flat config — applies to all repos
        return try parse(yaml: contents)
    }

    /// Parse a projects-list config and return the config for the first matching pattern.
    /// Returns nil if no pattern matches the repo root.
    static func parseProjectsList(
        _ projects: [String: Any],
        repoRoot: String,
    ) throws -> HooksConfig? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        for (pattern, value) in projects.sorted(by: { $0.key < $1.key }) {
            let expandedPattern = expandTilde(pattern, homeDir: homeDir)

            if matchesPattern(expandedPattern, path: repoRoot) {
                guard let hookDict = value as? [String: Any] else {
                    return HooksConfig()
                }

                let preCommit = parsePreCommit(hookDict["pre-commit"] as? [String: Any])
                let prePush = parsePrePush(hookDict["pre-push"] as? [String: Any])
                return HooksConfig(preCommit: preCommit, prePush: prePush)
            }
        }

        return nil
    }

    /// Expand `~` at the start of a path to the home directory.
    static func expandTilde(_ path: String, homeDir: String) -> String {
        if path == "~" {
            return homeDir
        }
        if path.hasPrefix("~/") {
            return (homeDir as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return path
    }

    /// Match a path against an fnmatch-style glob pattern.
    static func matchesPattern(_ pattern: String, path: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
    }

    /// Parse YAML string into HooksConfig.
    public static func parse(yaml: String) throws -> HooksConfig {
        guard let dict = try Yams.load(yaml: yaml) as? [String: Any] else {
            return HooksConfig()
        }

        let preCommit = parsePreCommit(dict["pre-commit"] as? [String: Any])
        let prePush = parsePrePush(dict["pre-push"] as? [String: Any])

        return HooksConfig(preCommit: preCommit, prePush: prePush)
    }

    private static func parsePreCommit(_ dict: [String: Any]?) -> PreCommitConfig {
        guard let dict else { return PreCommitConfig() }
        let tasks = parseTasks(dict["tasks"] as? [[String: Any]])
        return PreCommitConfig(tasks: tasks)
    }

    private static func parsePrePush(_ dict: [String: Any]?) -> PrePushConfig {
        guard let dict else { return PrePushConfig() }

        let commitMessage = parseCommitMessage(dict["commit-message"] as? [String: Any])
        let branchName = parseBranchName(dict["branch-name"] as? [String: Any])
        let workScope = parseWorkScope(dict["work-scope"] as? [String: Any])
        let rejectTrailers = dict["reject-trailers"] as? [String] ?? []
        let testOverride = parseTestOverride(dict["test-override"] as? [String: Any])
        let prSize = parsePRSize(dict["pr-size"] as? [String: Any])

        let tasks = parseTasks(dict["tasks"] as? [[String: Any]])

        return PrePushConfig(
            commitMessage: commitMessage,
            branchName: branchName,
            workScope: workScope,
            rejectTrailers: rejectTrailers,
            testOverride: testOverride,
            prSize: prSize,
            tasks: tasks,
        )
    }

    private static func parseCommitMessage(_ dict: [String: Any]?) -> CommitMessageConfig? {
        guard let dict,
              let pattern = dict["pattern"] as? String,
              let error = dict["error"] as? String else { return nil }
        let base = (dict["base"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CommitMessageConfig(pattern: pattern, error: error, base: base)
    }

    private static func parseBranchName(_ dict: [String: Any]?) -> BranchNameConfig? {
        guard let dict,
              let pattern = dict["pattern"] as? String,
              let error = dict["error"] as? String else { return nil }
        let skip = dict["skip"] as? [String] ?? []
        return BranchNameConfig(pattern: pattern, error: error, skip: skip)
    }

    private static func parseWorkScope(_ dict: [String: Any]?) -> WorkScopeConfig? {
        guard let dict, let base = dict["base"] as? String, !base.isEmpty else { return nil }

        let walk: WalkStrategy
        if let walkString = dict["walk"] as? String {
            if let parsed = WalkStrategy(rawValue: walkString) {
                walk = parsed
            } else {
                print(
                    "[WARN] Unknown work-scope.walk '\(walkString)'. Valid: default, first-parent. Using first-parent.",
                )
                walk = .firstParent
            }
        } else {
            walk = .firstParent
        }

        let commitFilter = parseCommitFilter(dict["commit-filter"] as? [String: Any])

        return WorkScopeConfig(base: base, walk: walk, commitFilter: commitFilter)
    }

    private static func parseCommitFilter(_ dict: [String: Any]?) -> CommitFilterConfig? {
        guard let dict,
              let branchPattern = dict["branch-pattern"] as? String,
              let commitPattern = dict["commit-pattern"] as? String else { return nil }

        let onMismatch: MismatchAction
        if let value = dict["on-mismatch"] as? String {
            if let parsed = MismatchAction(rawValue: value) {
                onMismatch = parsed
            } else {
                print(
                    "[WARN] Unknown work-scope.commit-filter.on-mismatch '\(value)'. Valid: skip, warn, fail. Using warn.",
                )
                onMismatch = .warn
            }
        } else {
            onMismatch = .warn
        }

        let includeMerges = dict["include-merges"] as? Bool ?? true

        return CommitFilterConfig(
            branchPattern: branchPattern,
            commitPattern: commitPattern,
            onMismatch: onMismatch,
            includeMerges: includeMerges,
        )
    }

    private static func parsePRSize(_ dict: [String: Any]?) -> PRSizeConfig? {
        guard let dict else { return nil }

        let mode: PRSizeConfig.Mode
        if let value = dict["mode"] as? String {
            if let parsed = PRSizeConfig.Mode(rawValue: value) {
                mode = parsed
            } else {
                print(
                    "[WARN] Unknown pr-size.mode '\(value)'. Valid: warn, fail. Using warn.",
                )
                mode = .warn
            }
        } else {
            mode = .warn
        }

        let defaults = PRSizeConfig()
        // Tri-state semantics for thresholds and weights:
        //   key absent       → use default
        //   key = null / ~   → explicit nil (disables the check)
        //   key = number     → use that value
        // Without this distinction, `max-additions: null` would silently fall back
        // to the default 800 — a misconfiguration footgun under `mode: fail`.
        let maxAdditions = readInt(dict, "max-additions", default: defaults.maxAdditions)
        let maxDeletions = readInt(dict, "max-deletions", default: defaults.maxDeletions)
        let maxFiles = readInt(dict, "max-files", default: defaults.maxFiles)
        let maxScatter = readDouble(dict, "max-scatter", default: defaults.maxScatter)
        let maxCognitive = readDouble(dict, "max-cognitive-score", default: defaults.maxCognitiveScore)
        let volumeWeight = readDouble(dict, "volume-weight", default: defaults.volumeWeight) ?? defaults.volumeWeight
        let scatterWeight = readDouble(dict, "scatter-weight", default: defaults.scatterWeight)
            ?? defaults.scatterWeight
        let testCompensation = readDouble(dict, "test-compensation", default: defaults.testCompensation)
            ?? defaults.testCompensation
        let exclude = dict["exclude"] as? [String] ?? []
        // Distinguish "key absent" from "explicit empty list": the latter disables defaults.
        let testPatterns = dict["test-patterns"] as? [String]

        return PRSizeConfig(
            mode: mode,
            maxAdditions: maxAdditions,
            maxDeletions: maxDeletions,
            maxFiles: maxFiles,
            maxScatter: maxScatter,
            maxCognitiveScore: maxCognitive,
            volumeWeight: volumeWeight,
            scatterWeight: scatterWeight,
            testCompensation: testCompensation,
            exclude: exclude,
            testPatterns: testPatterns,
        )
    }

    /// Read an optional int with tri-state semantics: missing key falls back to
    /// `default`, an explicit YAML null returns nil, a parseable number is returned.
    /// Unparseable values fall back to `default` so a typo doesn't silently disable.
    private static func readInt(_ dict: [String: Any], _ key: String, default fallback: Int?) -> Int? {
        guard let raw = dict[key] else { return fallback }
        if raw is NSNull { return nil }
        if let int = raw as? Int { return int }
        if let str = raw as? String, let parsed = Int(str) { return parsed }
        return fallback
    }

    /// Same as `readInt`, but for Double; accepts Int, Double, and numeric strings.
    private static func readDouble(_ dict: [String: Any], _ key: String, default fallback: Double?) -> Double? {
        guard let raw = dict[key] else { return fallback }
        if raw is NSNull { return nil }
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let str = raw as? String, let parsed = Double(str) { return parsed }
        return fallback
    }

    private static func parseTestOverride(_ dict: [String: Any]?) -> TestOverride? {
        guard let dict, let typeString = dict["type"] as? String else { return nil }
        guard let runnerType = TestRunnerType(rawValue: typeString) else {
            print("[WARN] Unknown test-override type '\(typeString)'. Valid: xcodebuild, swift, gradle.")
            return nil
        }
        return TestOverride(
            type: runnerType,
            project: dict["project"] as? String,
            scheme: dict["scheme"] as? String,
            testPlan: dict["test-plan"] as? String,
            destination: dict["destination"] as? String,
            broadImpactPaths: dict["broad-impact-paths"] as? [String],
            task: dict["task"] as? String,
            extraArgs: dict["extra-args"] as? [String],
        )
    }

    private static func parseTasks(_ array: [[String: Any]]?) -> [CustomTask] {
        guard let array else { return [] }
        return array.compactMap { dict -> CustomTask? in
            guard let name = dict["name"] as? String,
                  let run = dict["run"] as? String else {
                let keys = dict.keys.sorted().joined(separator: ", ")
                print("[WARN] Skipping malformed task (keys: \(keys)). Required: name, run.")
                return nil
            }

            let restage: RestageConfig? = if let val = dict["restage"] {
                if let flag = val as? Bool, flag {
                    .matchedFiles
                } else if let paths = val as? [String] {
                    .paths(paths)
                } else {
                    nil
                }
            } else {
                nil
            }

            return CustomTask(
                name: name,
                run: run,
                onFiles: dict["on-files"] as? [String],
                restage: restage,
                after: dict["after"] as? String,
                timeout: dict["timeout"] as? Int,
            )
        }
    }
}
