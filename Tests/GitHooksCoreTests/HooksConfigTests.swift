import Foundation
import GitHooksCore
import Testing

struct HooksConfigTests {
    @Test
    func `parse empty YAML`() throws {
        let config = try HooksConfig.parse(yaml: "")
        #expect(config.preCommit.tasks.isEmpty)
        #expect(config.prePush.commitMessage == nil)
        #expect(config.prePush.rejectTrailers.isEmpty)
        #expect(config.prePush.testOverride == nil)
    }

    @Test
    func `parse pre commit tasks`() throws {
        let yaml = """
            pre-commit:
              tasks:
                - name: "Lint strings"
                  run: "swift scripts/lint.swift"
                  on-files:
                    - "*.strings"
                  restage: true
                  timeout: 60
                - name: "Swiftgen"
                  run: "swiftgen config run"
                  after: "Lint strings"
                  restage:
                    - "Generated/"
                  timeout: 30
            """

        let config = try HooksConfig.parse(yaml: yaml)

        #expect(config.preCommit.tasks.count == 2)

        let first = config.preCommit.tasks[0]
        #expect(first.name == "Lint strings")
        #expect(first.run == "swift scripts/lint.swift")
        #expect(first.onFiles == ["*.strings"])
        #expect(first.restage == .matchedFiles)
        #expect(first.timeout == 60)

        let second = config.preCommit.tasks[1]
        #expect(second.name == "Swiftgen")
        #expect(second.after == "Lint strings")
        #expect(second.restage == .paths(["Generated/"]))
    }

    @Test
    func `parse pre push commit message`() throws {
        let yaml = """
            pre-push:
              commit-message:
                pattern: "^PROJ-\\\\d{4}\\\\s"
                error: "Must start with PROJ-XXXX"
              reject-trailers:
                - "Co-authored-by"
            """

        let config = try HooksConfig.parse(yaml: yaml)

        #expect(config.prePush.commitMessage?.pattern == "^PROJ-\\d{4}\\s")
        #expect(config.prePush.commitMessage?.error == "Must start with PROJ-XXXX")
        #expect(config.prePush.commitMessage?.base == nil)
        #expect(config.prePush.rejectTrailers == ["Co-authored-by"])
    }

    @Test
    func `parse pre push commit message with base`() throws {
        let yaml = """
            pre-push:
              commit-message:
                pattern: "^PROJ-\\\\d{4}\\\\s"
                error: "Must start with PROJ-XXXX"
                base: "origin/develop"
            """

        let config = try HooksConfig.parse(yaml: yaml)

        #expect(config.prePush.commitMessage?.base == "origin/develop")
    }

    @Test
    func `parse pre push commit message treats empty base as nil`() throws {
        let yaml = """
            pre-push:
              commit-message:
                pattern: "^X"
                error: "x"
                base: ""
            """

        let config = try HooksConfig.parse(yaml: yaml)

        #expect(config.prePush.commitMessage?.base == nil)
    }

    @Test
    func `parse pr-size full config`() throws {
        let yaml = """
            pre-push:
              pr-size:
                mode: fail
                max-additions: 500
                max-deletions: 400
                max-files: 20
                max-cognitive-score: 15.0
                max-scatter: 3.5
                volume-weight: 1.2
                scatter-weight: 0.8
                test-compensation: 0.5
                exclude:
                  - "Generated/*"
                  - "Package.resolved"
                test-patterns:
                  - "Specs/*"
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.prePush.prSize)

        #expect(prSize.mode == .fail)
        #expect(prSize.maxAdditions == 500)
        #expect(prSize.maxDeletions == 400)
        #expect(prSize.maxFiles == 20)
        #expect(prSize.maxCognitiveScore == 15.0)
        #expect(prSize.maxScatter == 3.5)
        #expect(prSize.volumeWeight == 1.2)
        #expect(prSize.scatterWeight == 0.8)
        #expect(prSize.testCompensation == 0.5)
        #expect(prSize.exclude == ["Generated/*", "Package.resolved"])
        #expect(prSize.testPatterns == ["Specs/*"])
    }

    @Test
    func `parse pr-size defaults when block is empty`() throws {
        let yaml = """
            pre-push:
              pr-size: {}
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.prePush.prSize)
        let defaults = HooksConfig.PRSizeConfig()

        #expect(prSize.mode == defaults.mode)
        #expect(prSize.maxAdditions == defaults.maxAdditions)
        #expect(prSize.maxCognitiveScore == defaults.maxCognitiveScore)
        #expect(prSize.testCompensation == defaults.testCompensation)
        #expect(prSize.testPatterns == nil)
        #expect(prSize.effectiveTestPatterns == HooksConfig.PRSizeConfig.defaultTestPatterns)
    }

    @Test
    func `parse pr-size unknown mode falls back to warn`() throws {
        let yaml = """
            pre-push:
              pr-size:
                mode: nuke
            """

        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.prSize?.mode == .warn)
    }

    @Test
    func `parse pr-size empty test-patterns disables defaults`() throws {
        let yaml = """
            pre-push:
              pr-size:
                test-patterns: []
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.prePush.prSize)

        #expect(prSize.testPatterns == [])
        #expect(prSize.effectiveTestPatterns == [])
    }

    @Test
    func `parse pr-size explicit null disables threshold`() throws {
        // YAML null on a threshold should disable it (not fall back to the default).
        let yaml = """
            pre-push:
              pr-size:
                max-additions: ~
                max-deletions: null
                max-cognitive-score: null
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.prePush.prSize)

        #expect(prSize.maxAdditions == nil)
        #expect(prSize.maxDeletions == nil)
        #expect(prSize.maxCognitiveScore == nil)
        // Untouched keys keep their defaults
        #expect(prSize.maxFiles == HooksConfig.PRSizeConfig().maxFiles)
    }

    @Test
    func `parse pr-size weight null falls back to default`() throws {
        // Weights are non-nullable on the struct; an explicit null is treated as
        // "use the default" since a weight of 0 already means "disable that term".
        let yaml = """
            pre-push:
              pr-size:
                volume-weight: ~
                scatter-weight: ~
                test-compensation: ~
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.prePush.prSize)
        let defaults = HooksConfig.PRSizeConfig()

        #expect(prSize.volumeWeight == defaults.volumeWeight)
        #expect(prSize.scatterWeight == defaults.scatterWeight)
        #expect(prSize.testCompensation == defaults.testCompensation)
    }

    @Test
    func `pr-size is nil when not configured`() throws {
        let yaml = """
            pre-push:
              commit-message:
                pattern: "."
                error: "x"
            """

        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.prSize == nil)
        #expect(config.preCommit.prSize == nil)
    }

    @Test
    func `parse pre-commit pr-size full config`() throws {
        let yaml = """
            pre-commit:
              pr-size:
                mode: fail
                max-additions: 300
                max-cognitive-score: 12.0
                exclude:
                  - "Generated/*"
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.preCommit.prSize)

        #expect(prSize.mode == .fail)
        #expect(prSize.maxAdditions == 300)
        #expect(prSize.maxCognitiveScore == 12.0)
        #expect(prSize.exclude == ["Generated/*"])
        // pre-push pr-size remains independent
        #expect(config.prePush.prSize == nil)
    }

    @Test
    func `parse pre-commit and pre-push pr-size are independent`() throws {
        let yaml = """
            pre-commit:
              pr-size:
                mode: warn
                max-additions: 200
            pre-push:
              pr-size:
                mode: fail
                max-additions: 800
            """

        let config = try HooksConfig.parse(yaml: yaml)

        #expect(config.preCommit.prSize?.mode == .warn)
        #expect(config.preCommit.prSize?.maxAdditions == 200)
        #expect(config.prePush.prSize?.mode == .fail)
        #expect(config.prePush.prSize?.maxAdditions == 800)
    }

    @Test
    func `parse pre-commit pr-size defaults when block is empty`() throws {
        let yaml = """
            pre-commit:
              pr-size: {}
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let prSize = try #require(config.preCommit.prSize)
        let defaults = HooksConfig.PRSizeConfig()

        #expect(prSize.mode == defaults.mode)
        #expect(prSize.maxAdditions == defaults.maxAdditions)
        #expect(prSize.maxCognitiveScore == defaults.maxCognitiveScore)
    }

    @Test
    func `parse test override`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: xcodebuild
                project: "App.xcodeproj"
                scheme: "AppTests"
                test-plan: "config/tests.xctestplan"
                destination: "platform=iOS Simulator,name=iPhone 16"
                broad-impact-paths:
                  - "App.xcodeproj/"
                  - "Package.swift"
            """

        let config = try HooksConfig.parse(yaml: yaml)
        let override = config.prePush.testOverride

        #expect(override?.type == .xcodebuild)
        #expect(override?.project == "App.xcodeproj")
        #expect(override?.scheme == "AppTests")
        #expect(override?.testPlan == "config/tests.xctestplan")
        #expect(override?.destination == "platform=iOS Simulator,name=iPhone 16")
        #expect(override?.broadImpactPaths == ["App.xcodeproj/", "Package.swift"])
    }

    @Test
    func `load returns nil when no config file`() throws {
        let config = try HooksConfig.load(repoRoot: "/tmp/nonexistent-\(UUID())")
        #expect(config == nil)
    }

    @Test
    func `load reads from file`() throws {
        let dir = try makeTempDir(prefix: "config-load")
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
            pre-push:
              reject-trailers:
                - "Signed-off-by"
            """

        try yaml.write(
            to: dir.appendingPathComponent(".project-hooks.yml"),
            atomically: true,
            encoding: .utf8,
        )

        let config = try HooksConfig.load(repoRoot: dir.path)
        #expect(config?.prePush.rejectTrailers == ["Signed-off-by"])
    }

    @Test
    func `parse pre push tasks along with commit message`() throws {
        let yaml = """
            pre-push:
              commit-message:
                pattern: "^FIX-\\\\d+"
                error: "Need ticket"
              tasks:
                - name: "Changelog"
                  run: "scripts/check-changelog.sh"
            """

        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.commitMessage != nil)
        #expect(config.prePush.tasks.count == 1)
        #expect(config.prePush.tasks[0].name == "Changelog")
    }

    @Test
    func `parse gradle test override with task`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: gradle
                task: ":base:testDevelopDebugUnitTest"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let override = try #require(config.prePush.testOverride)
        #expect(override.type == .gradle)
        #expect(override.task == ":base:testDevelopDebugUnitTest")
    }

    @Test
    func `gradle test override task is optional`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: gradle
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.testOverride?.task == nil)
    }

    @Test
    func `parse extra-args on test override`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: xcodebuild
                scheme: "App"
                extra-args:
                  - "-skipPackagePluginValidation"
                  - "-quiet"
                  - "OTHER_SWIFT_FLAGS=-D SKIP_FORMAT"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let override = try #require(config.prePush.testOverride)
        #expect(
            override.extraArgs == [
                "-skipPackagePluginValidation",
                "-quiet",
                "OTHER_SWIFT_FLAGS=-D SKIP_FORMAT",
            ])
    }

    @Test
    func `extra-args is optional`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: gradle
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.testOverride?.extraArgs == nil)
    }

    @Test
    func `parse test override skip flag`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: xcodebuild
                skip: true
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let override = try #require(config.prePush.testOverride)
        #expect(override.skip)
        #expect(override.type == .xcodebuild)
    }

    @Test
    func `parse test override skip without type`() throws {
        let yaml = """
            pre-push:
              test-override:
                skip: true
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let override = try #require(config.prePush.testOverride)
        #expect(override.skip)
    }

    @Test
    func `parse test override defaults skip to false`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: xcodebuild
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let override = try #require(config.prePush.testOverride)
        #expect(!override.skip)
    }

    @Test
    func `override without type and without skip is rejected`() throws {
        let yaml = """
            pre-push:
              test-override:
                destination: "platform=iOS Simulator,name=iPhone 17"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.testOverride == nil)
    }

    @Test
    func `parse test override rejects unknown type`() throws {
        let yaml = """
            pre-push:
              test-override:
                type: xocedubild
                project: "App.xcodeproj"
            """

        let config = try HooksConfig.parse(yaml: yaml)
        // Unknown type should be rejected at parse time, not silently passed through
        #expect(config.prePush.testOverride == nil)
    }

    @Test
    func `parse branch name`() throws {
        let yaml = """
            pre-push:
              branch-name:
                pattern: "^(feature|bugfix)/.+"
                error: "Bad branch"
                skip:
                  - "main"
                  - "develop"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let branch = try #require(config.prePush.branchName)
        #expect(branch.pattern == "^(feature|bugfix)/.+")
        #expect(branch.error == "Bad branch")
        #expect(branch.skip == ["main", "develop"])
    }

    @Test
    func `branch name skip defaults to empty`() throws {
        let yaml = """
            pre-push:
              branch-name:
                pattern: ".+"
                error: "x"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.branchName?.skip == [])
    }

    @Test
    func `branch name requires both pattern and error`() throws {
        let yaml = """
            pre-push:
              branch-name:
                pattern: ".+"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.branchName == nil)
    }

    @Test
    func `parse work scope minimal`() throws {
        let yaml = """
            pre-push:
              work-scope:
                base: "origin/develop"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let scope = try #require(config.prePush.workScope)
        #expect(scope.base == "origin/develop")
        #expect(scope.walk == .firstParent)  // default
        #expect(scope.commitFilter == nil)
    }

    @Test
    func `parse work scope with explicit walk default`() throws {
        let yaml = """
            pre-push:
              work-scope:
                base: "origin/main"
                walk: default
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.workScope?.walk == .default)
    }

    @Test
    func `parse work scope unknown walk falls back to first parent`() throws {
        let yaml = """
            pre-push:
              work-scope:
                base: "origin/main"
                walk: nonsense
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.workScope?.walk == .firstParent)
    }

    @Test
    func `work scope without base is ignored`() throws {
        let yaml = """
            pre-push:
              work-scope:
                walk: first-parent
            """
        let config = try HooksConfig.parse(yaml: yaml)
        #expect(config.prePush.workScope == nil)
    }

    @Test
    func `parse work scope commit filter`() throws {
        let yaml = """
            pre-push:
              work-scope:
                base: "origin/develop"
                commit-filter:
                  branch-pattern: "MAIN-\\\\d+"
                  commit-pattern: "^MAIN-\\\\d+"
                  on-mismatch: fail
                  include-merges: false
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let filter = try #require(config.prePush.workScope?.commitFilter)
        #expect(filter.branchPattern == "MAIN-\\d+")
        #expect(filter.commitPattern == "^MAIN-\\d+")
        #expect(filter.onMismatch == .fail)
        #expect(filter.includeMerges == false)
    }

    @Test
    func `commit filter defaults`() throws {
        let yaml = """
            pre-push:
              work-scope:
                base: "origin/develop"
                commit-filter:
                  branch-pattern: "X-\\\\d+"
                  commit-pattern: "^X-\\\\d+"
            """
        let config = try HooksConfig.parse(yaml: yaml)
        let filter = try #require(config.prePush.workScope?.commitFilter)
        #expect(filter.onMismatch == .warn)
        #expect(filter.includeMerges == true)
    }
}
