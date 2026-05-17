import Foundation
import GitHooksCore
import Testing

struct PRSizeMetricTests {
    // MARK: - numstat parsing

    @Test
    func `parse numstat plain text format`() {
        let raw = """
            10\t2\tSources/Foo.swift
            5\t0\tSources/Bar.swift
            -\t-\tdocs/diagram.png
            """

        let stats = PRSizeMetric.parseNumstat(raw)

        #expect(stats.count == 3)
        #expect(stats[0] == PRSizeMetric.FileStat(path: "Sources/Foo.swift", added: 10, deleted: 2))
        #expect(stats[1] == PRSizeMetric.FileStat(path: "Sources/Bar.swift", added: 5, deleted: 0))
        #expect(stats[2].isBinary)
        #expect(stats[2].added == 0)
        #expect(stats[2].deleted == 0)
    }

    @Test
    func `parse numstat -z NUL-separated`() throws {
        var data = Data()
        try data.append(#require("10\t2\tSources/Foo.swift".data(using: .utf8)))
        data.append(0)
        try data.append(#require("5\t0\tSources/Bar.swift".data(using: .utf8)))
        data.append(0)

        let stats = PRSizeMetric.parseNumstatZ(data)

        #expect(stats.count == 2)
        #expect(stats[0].path == "Sources/Foo.swift")
        #expect(stats[0].added == 10)
        #expect(stats[1].path == "Sources/Bar.swift")
    }

    @Test
    func `parse numstat skips malformed lines`() {
        let raw = """
            10\t2\tSources/Foo.swift
            garbage line
            \t\t
            5\t0\tSources/Bar.swift
            """

        let stats = PRSizeMetric.parseNumstat(raw)

        // "\t\t" parses to path == "" which is rejected; "garbage line" lacks tabs.
        #expect(stats.count == 2)
        #expect(stats.map(\.path) == ["Sources/Foo.swift", "Sources/Bar.swift"])
    }

    // MARK: - cognitive score

    @Test
    func `tiny PR scores small with no violations`() {
        let stats = [
            PRSizeMetric.FileStat(path: "Sources/Foo.swift", added: 20, deleted: 5),
            PRSizeMetric.FileStat(path: "Tests/FooTests.swift", added: 15, deleted: 0),
        ]

        let result = PRSizeMetric.compute(stats: stats, config: HooksConfig.PRSizeConfig())

        #expect(result.score.additions == 20)
        #expect(result.score.deletions == 5)
        #expect(result.score.files == 1)
        #expect(result.score.testFiles == 1)
        #expect(result.score.band == .small)
        #expect(result.violations.isEmpty)
    }

    @Test
    func `large additions triggers additions violation`() {
        var stats: [PRSizeMetric.FileStat] = []
        for index in 0..<5 {
            stats.append(
                PRSizeMetric.FileStat(
                    path: "Sources/File\(index).swift",
                    added: 300,
                    deleted: 0,
                ))
        }
        let config = HooksConfig.PRSizeConfig(maxAdditions: 800)

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.score.additions == 1500)
        let additionsViolation = result.violations.first { $0.metric == "additions" }
        #expect(additionsViolation != nil)
        #expect(additionsViolation?.value == 1500.0)
        #expect(additionsViolation?.threshold == 800.0)
    }

    @Test
    func `scattered changes raise scatter and cognitive score`() {
        // 30 files, each touching 40 lines → maximum entropy + high volume.
        // Volume = ln(1201) ≈ 7.09; scatter = 1.0 * ln(31) ≈ 3.43; total ≈ 10.52 → large.
        var stats: [PRSizeMetric.FileStat] = []
        for index in 0..<30 {
            stats.append(
                PRSizeMetric.FileStat(
                    path: "Sources/Module\(index)/File.swift",
                    added: 40,
                    deleted: 0,
                ))
        }

        let result = PRSizeMetric.compute(
            stats: stats,
            config: HooksConfig.PRSizeConfig(),
        )

        #expect(result.score.volume > 7.0)
        // Maximum entropy normalized to 1.0
        #expect(result.score.entropy > 0.99)
        #expect(result.score.scatter > 3.0)
        #expect(result.score.cognitiveScore > 10.0)
        #expect(result.score.band == .large || result.score.band == .oversized)
    }

    @Test
    func `concentrated single-file changes have near-zero scatter`() {
        let stats = [
            PRSizeMetric.FileStat(path: "Sources/Big.swift", added: 500, deleted: 100)
        ]

        let result = PRSizeMetric.compute(
            stats: stats,
            config: HooksConfig.PRSizeConfig(),
        )

        #expect(result.score.scatter == 0.0)
        #expect(result.score.entropy == 0.0)
        #expect(result.score.files == 1)
    }

    @Test
    func `tests reduce cognitive score but not below the cap`() {
        let half: [PRSizeMetric.FileStat] = [
            .init(path: "Sources/Foo.swift", added: 100, deleted: 0),
            .init(path: "Tests/FooTests.swift", added: 100, deleted: 0),
        ]
        let mostlyTests: [PRSizeMetric.FileStat] = [
            .init(path: "Sources/Foo.swift", added: 100, deleted: 0),
            .init(path: "Tests/FooTests.swift", added: 900, deleted: 0),
        ]

        let halfResult = PRSizeMetric.compute(stats: half, config: HooksConfig.PRSizeConfig())
        let testHeavyResult = PRSizeMetric.compute(stats: mostlyTests, config: HooksConfig.PRSizeConfig())

        // Both have the same prod volume; test-heavy should score lower (more comp), but
        // never fall below 75% of the original (default cap = 0.25).
        let baselineVolume = halfResult.score.volume
        let lowerBound = baselineVolume * 0.75
        #expect(testHeavyResult.score.cognitiveScore >= lowerBound - 0.0001)
        #expect(testHeavyResult.score.cognitiveScore < halfResult.score.cognitiveScore)
    }

    @Test
    func `exclude patterns skip generated files entirely`() {
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "Sources/Foo.swift", added: 10, deleted: 0),
            .init(path: "Generated/Strings.swift", added: 5000, deleted: 0),
            .init(path: "Package.resolved", added: 50, deleted: 0),
        ]
        let config = HooksConfig.PRSizeConfig(
            maxAdditions: 100,
            exclude: ["Generated/*", "Package.resolved"],
        )

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.score.additions == 10)
        #expect(result.score.files == 1)
        #expect(result.violations.isEmpty)
    }

    @Test
    func `custom test patterns override defaults`() {
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "Sources/Foo.swift", added: 100, deleted: 0),
            // Default classifier would treat this as a test; the explicit list excludes it.
            .init(path: "Tests/FooTests.swift", added: 100, deleted: 0),
            // Custom pattern routes this to test.
            .init(path: "MyChecks/FooCheck.swift", added: 200, deleted: 0),
        ]
        let config = HooksConfig.PRSizeConfig(testPatterns: ["MyChecks/*"])

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.score.testFiles == 1)
        #expect(result.score.testAdditions == 200)
        #expect(result.score.additions == 200)  // Foo + FooTests now both prod
    }

    @Test
    func `empty test patterns disables test classification`() {
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "Tests/FooTests.swift", added: 500, deleted: 0)
        ]
        let config = HooksConfig.PRSizeConfig(testPatterns: [])

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.score.testFiles == 0)
        #expect(result.score.additions == 500)
    }

    @Test
    func `cognitive score threshold triggers violation`() {
        // Lots of files, lots of lines → high cognitive score
        var stats: [PRSizeMetric.FileStat] = []
        for index in 0..<25 {
            stats.append(.init(path: "Sources/F\(index).swift", added: 50, deleted: 10))
        }
        let config = HooksConfig.PRSizeConfig(
            maxAdditions: nil,
            maxDeletions: nil,
            maxFiles: nil,
            maxCognitiveScore: 8.0,
        )

        let result = PRSizeMetric.compute(stats: stats, config: config)

        let cognitiveViolation = result.violations.first { $0.metric == "cognitive-score" }
        #expect(cognitiveViolation != nil)
        #expect(result.score.cognitiveScore > 8.0)
    }

    @Test
    func `zero thresholds disable individual checks`() {
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "Sources/Foo.swift", added: 100_000, deleted: 0)
        ]
        let config = HooksConfig.PRSizeConfig(
            maxAdditions: 0,
            maxDeletions: 0,
            maxFiles: 0,
            maxScatter: 0,
            maxCognitiveScore: 0,
        )

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.violations.isEmpty)
    }

    @Test
    func `weight zero on volume eliminates volume contribution`() {
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "Sources/Foo.swift", added: 1000, deleted: 0)
        ]
        let config = HooksConfig.PRSizeConfig(volumeWeight: 0.0, scatterWeight: 0.0)

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.score.volume == 0.0)
        #expect(result.score.cognitiveScore == 0.0)
    }

    @Test
    func `mode-only changes are excluded from the score`() {
        // Permission-only changes show up as 0/0 non-binary records. They shouldn't
        // inflate file count or trigger maxFiles violations.
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "scripts/run.sh", added: 0, deleted: 0),
            .init(path: "scripts/build.sh", added: 0, deleted: 0),
            .init(path: "Sources/Foo.swift", added: 5, deleted: 0),
        ]
        let config = HooksConfig.PRSizeConfig(maxFiles: 2)

        let result = PRSizeMetric.compute(stats: stats, config: config)

        #expect(result.score.files == 1)
        #expect(result.violations.isEmpty)
    }

    @Test
    func `binary files do not contribute to line counts`() {
        let stats: [PRSizeMetric.FileStat] = [
            .init(path: "docs/screenshot.png", added: 0, deleted: 0, isBinary: true),
            .init(path: "Sources/Foo.swift", added: 10, deleted: 0),
        ]

        let result = PRSizeMetric.compute(
            stats: stats,
            config: HooksConfig.PRSizeConfig(),
        )

        // Binary file still counts toward `files` since reviewer must acknowledge it,
        // but contributes 0 to line counts.
        #expect(result.score.files == 2)
        #expect(result.score.additions == 10)
        #expect(result.score.deletions == 0)
    }
}
