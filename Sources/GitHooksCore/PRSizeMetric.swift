import Foundation

/// Quantifies whether a pull request is "too big" to review effectively, based on
/// the additions/deletions per file produced by `git diff --numstat`.
///
/// The composite cognitive-load score combines three terms grounded in empirical
/// software-engineering research:
///
/// 1. **Volume** — `ln(1 + A + D)` where `A`/`D` are non-test added/deleted lines.
///    Log-scaling reflects that review effort and defect-detection rate degrade
///    sub-linearly with raw line count (Halstead 1977; threshold effects in
///    Posnett, Bird & Devanbu MSR 2011; SmartBear/Cisco's 200–400 LOC inflection
///    reported in Cohen 2006).
///
/// 2. **Scatter** — Shannon entropy `H = -Σ p_i · ln(p_i)` of per-file change
///    fractions, normalized to `[0, 1]` and scaled by `ln(1 + F)` where `F`
///    is the number of non-test files touched. Hassan's "complexity of code
///    changes" (ICSE 2009) found entropy outperforms raw LOC as a fault
///    predictor; Nagappan et al. (ISSRE 2010) showed file-count bursts are
///    an independent defect signal.
///
/// 3. **Test compensation** — a multiplicative discount proportional to the
///    fraction of total changed lines that live in test files, capped at a
///    configurable maximum (default 25 %). Tests reduce production risk and
///    evidence due diligence (Kononenko et al. ICSE 2016) but reviewers still
///    have to read them, so the discount is bounded.
///
/// Final score: `CL = (volume · w_v + scatter · w_s) · (1 − min(test_ratio, 1) · cap)`.
///
/// Band boundaries default to:
/// - Small: `CL < 5`     — within Google's median ~24 LOC, 2–3 files (Sadowski et al. ICSE 2018).
/// - Medium: `5 ≤ CL < 10` — at Rigby & Bird's OSS median ~44 LOC (FSE 2013).
/// - Large: `10 ≤ CL < 18` — approaching the SmartBear/Cohen 200-LOC inflection.
/// - Oversized: `CL ≥ 18`   — above Cohen's 400-LOC ceiling.
///
/// Every weight and threshold is tunable through `pre-push.pr-size` in the
/// project configuration; the defaults target a small-to-medium product team.
public enum PRSizeMetric {
    /// Hardcoded band boundaries derived from the literature above. The
    /// configurable `max-cognitive-score` threshold determines the *block*
    /// behavior; bands are purely informational for the report.
    public enum Band: String, Equatable, Sendable {
        case small
        case medium
        case large
        case oversized

        public static let smallMax: Double = 5.0
        public static let mediumMax: Double = 10.0
        public static let largeMax: Double = 18.0

        public var label: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .oversized: "Oversized"
            }
        }
    }

    /// A single file's contribution to the diff. `added`/`deleted` are line counts;
    /// binary files report 0/0 and set `isBinary` so callers can surface them in reports.
    public struct FileStat: Equatable, Sendable {
        public let path: String
        public let added: Int
        public let deleted: Int
        public let isBinary: Bool

        public init(path: String, added: Int, deleted: Int, isBinary: Bool = false) {
            self.path = path
            self.added = added
            self.deleted = deleted
            self.isBinary = isBinary
        }

        public var changed: Int {
            added + deleted
        }
    }

    public struct Score: Equatable, Sendable {
        public let additions: Int
        public let deletions: Int
        public let files: Int
        public let testFiles: Int
        public let testAdditions: Int
        public let testDeletions: Int
        public let volume: Double
        public let scatter: Double
        public let entropy: Double
        public let testRatio: Double
        public let cognitiveScore: Double
        public let band: Band

        public init(
            additions: Int,
            deletions: Int,
            files: Int,
            testFiles: Int,
            testAdditions: Int,
            testDeletions: Int,
            volume: Double,
            scatter: Double,
            entropy: Double,
            testRatio: Double,
            cognitiveScore: Double,
            band: Band,
        ) {
            self.additions = additions
            self.deletions = deletions
            self.files = files
            self.testFiles = testFiles
            self.testAdditions = testAdditions
            self.testDeletions = testDeletions
            self.volume = volume
            self.scatter = scatter
            self.entropy = entropy
            self.testRatio = testRatio
            self.cognitiveScore = cognitiveScore
            self.band = band
        }
    }

    public struct Violation: Equatable, Sendable {
        public let metric: String
        public let value: Double
        public let threshold: Double
        public let message: String

        public init(metric: String, value: Double, threshold: Double, message: String) {
            self.metric = metric
            self.value = value
            self.threshold = threshold
            self.message = message
        }
    }

    public struct Result: Equatable, Sendable {
        public let score: Score
        public let violations: [Violation]

        public init(score: Score, violations: [Violation]) {
            self.score = score
            self.violations = violations
        }
    }

    /// Compute the score and any threshold violations for `stats` under `config`.
    /// Excluded files are dropped before any aggregation. Test files contribute
    /// only to the compensation factor, never to volume or scatter.
    public static func compute(
        stats: [FileStat],
        config: HooksConfig.PRSizeConfig,
    ) -> Result {
        let included = stats.filter { stat in
            // Drop mode-only changes (chmod without content edits): git reports them
            // as `0\t0\tpath` in numstat, but they impose no cognitive review cost.
            // Binary files (isBinary=true) are kept so reviewers see them in the report.
            if !stat.isBinary, stat.changed == 0 { return false }
            return config.exclude.isEmpty
                ? true
                : !FileGlobMatcher.matches(stat.path, patterns: config.exclude)
        }

        let testPatterns = config.effectiveTestPatterns
        let (test, prod) = included.partitioned { stat in
            !testPatterns.isEmpty && FileGlobMatcher.matches(stat.path, patterns: testPatterns)
        }

        let prodAdditions = prod.reduce(0) { $0 + $1.added }
        let prodDeletions = prod.reduce(0) { $0 + $1.deleted }
        let prodTotal = prodAdditions + prodDeletions
        let testAdditions = test.reduce(0) { $0 + $1.added }
        let testDeletions = test.reduce(0) { $0 + $1.deleted }
        let overallTotal = prodTotal + testAdditions + testDeletions

        let volumeRaw = log(1.0 + Double(prodTotal))
        let volume = volumeRaw * config.volumeWeight

        let (entropyNormalized, scatter) = entropyTerms(
            prod: prod,
            prodTotal: prodTotal,
            weight: config.scatterWeight,
        )

        let testRatio = overallTotal == 0
            ? 0.0
            : Double(testAdditions + testDeletions) / Double(overallTotal)
        let cap = max(0.0, min(config.testCompensation, 1.0))
        let testFactor = 1.0 - min(testRatio, 1.0) * cap

        let cognitive = (volume + scatter) * testFactor
        let band = classify(cognitive: cognitive)

        let score = Score(
            additions: prodAdditions,
            deletions: prodDeletions,
            files: prod.count,
            testFiles: test.count,
            testAdditions: testAdditions,
            testDeletions: testDeletions,
            volume: volume,
            scatter: scatter,
            entropy: entropyNormalized,
            testRatio: testRatio,
            cognitiveScore: cognitive,
            band: band,
        )

        return Result(score: score, violations: violations(for: score, config: config, scatter: scatter))
    }

    /// Parse the output of `git diff --no-renames --numstat -z REF..REF`. Records are
    /// `<added>\t<deleted>\t<path>` separated by NUL. Binary files report `-\t-\t<path>`
    /// and are surfaced with `isBinary = true` and zero line counts.
    public static func parseNumstatZ(_ data: Data) -> [FileStat] {
        var stats: [FileStat] = []
        for record in data.split(separator: 0) {
            guard let text = String(data: record, encoding: .utf8) else { continue }
            if let stat = parseRecord(text) { stats.append(stat) }
        }
        return stats
    }

    /// Parse newline-separated numstat output (no `-z`). Mainly useful for tests.
    public static func parseNumstat(_ text: String) -> [FileStat] {
        var stats: [FileStat] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let stat = parseRecord(String(line)) { stats.append(stat) }
        }
        return stats
    }

    // MARK: - Private

    private static func parseRecord(_ text: String) -> FileStat? {
        let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let addStr = String(parts[0])
        let delStr = String(parts[1])
        let path = String(parts[2])
        guard !path.isEmpty else { return nil }

        let isBinary = (addStr == "-" || delStr == "-")
        let added = isBinary ? 0 : Int(addStr) ?? 0
        let deleted = isBinary ? 0 : Int(delStr) ?? 0
        return FileStat(path: path, added: added, deleted: deleted, isBinary: isBinary)
    }

    private static func entropyTerms(
        prod: [FileStat],
        prodTotal: Int,
        weight: Double,
    ) -> (entropy: Double, scaled: Double) {
        guard prod.count > 1, prodTotal > 0 else { return (0.0, 0.0) }

        var entropy = 0.0
        for stat in prod where stat.changed > 0 {
            let p = Double(stat.changed) / Double(prodTotal)
            entropy -= p * log(p)
        }

        let maxEntropy = log(Double(prod.count))
        let normalized = maxEntropy > 0 ? entropy / maxEntropy : 0.0
        let scaled = normalized * log(1.0 + Double(prod.count)) * weight
        return (normalized, scaled)
    }

    private static func classify(cognitive: Double) -> Band {
        if cognitive < Band.smallMax { return .small }
        if cognitive < Band.mediumMax { return .medium }
        if cognitive < Band.largeMax { return .large }
        return .oversized
    }

    private static func violations(
        for score: Score,
        config: HooksConfig.PRSizeConfig,
        scatter: Double,
    ) -> [Violation] {
        var out: [Violation] = []

        if let limit = config.maxAdditions, limit > 0, score.additions > limit {
            out.append(Violation(
                metric: "additions",
                value: Double(score.additions),
                threshold: Double(limit),
                message: "Added \(score.additions) non-test lines (limit: \(limit)).",
            ))
        }
        if let limit = config.maxDeletions, limit > 0, score.deletions > limit {
            out.append(Violation(
                metric: "deletions",
                value: Double(score.deletions),
                threshold: Double(limit),
                message: "Deleted \(score.deletions) non-test lines (limit: \(limit)).",
            ))
        }
        if let limit = config.maxFiles, limit > 0, score.files > limit {
            out.append(Violation(
                metric: "files",
                value: Double(score.files),
                threshold: Double(limit),
                message: "Touched \(score.files) non-test files (limit: \(limit)).",
            ))
        }
        if let limit = config.maxScatter, limit > 0, scatter > limit {
            out.append(Violation(
                metric: "scatter",
                value: scatter,
                threshold: limit,
                message: String(format: "Scatter score %.2f exceeds limit %.2f.", scatter, limit),
            ))
        }
        if let limit = config.maxCognitiveScore, limit > 0, score.cognitiveScore > limit {
            out.append(Violation(
                metric: "cognitive-score",
                value: score.cognitiveScore,
                threshold: limit,
                message: String(
                    format: "Cognitive load %.2f exceeds limit %.2f (band: %@).",
                    score.cognitiveScore,
                    limit,
                    score.band.label,
                ),
            ))
        }

        return out
    }
}

// MARK: - Small helpers

private extension Array {
    /// Split into `(matching, nonMatching)` in a single pass.
    func partitioned(by predicate: (Element) -> Bool) -> (matching: [Element], nonMatching: [Element]) {
        var matching: [Element] = []
        var nonMatching: [Element] = []
        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                nonMatching.append(element)
            }
        }
        return (matching, nonMatching)
    }
}
