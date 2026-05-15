import Foundation

/// Parses test output from Swift Testing, XCTest, and Gradle to extract
/// pass/fail summaries, hanging test detection, and failure diagnostics.
public enum TestOutputParser {
    /// Find the last test that started but never finished — likely the one hanging.
    public static func findLastStartedTest(lines: [String]) -> String? {
        var startedTests: [String] = []
        var finishedTests: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // XCTest: "Test Case '-[SuiteTests testFoo]' started."
            // Check XCTest first (more specific) before the generic "Test" match
            if trimmed.contains("Test Case"), trimmed.contains("started") {
                startedTests.append(trimmed)
            }
            // Swift Testing: "Test someTest() started."
            else if trimmed.hasPrefix("Test "), trimmed.contains("started") {
                startedTests.append(trimmed)
            }
            // Gradle: "com.example.MyTest > testSomething STARTED"
            else if trimmed.hasSuffix("STARTED") {
                startedTests.append(trimmed)
            }

            // Track finished tests — same priority order
            if trimmed.contains("Test Case"), trimmed.contains("passed") || trimmed.contains("failed") {
                finishedTests.append(trimmed)
            } else if trimmed.hasPrefix("Test "), trimmed.contains(" passed") || trimmed.contains(" failed") {
                finishedTests.append(trimmed)
            }
        }

        // Walk backwards: find the last started test that has no matching finish
        for started in startedTests.reversed() {
            let testName = extractTestName(from: started)
            let hasFinished = finishedTests.contains { extractTestName(from: $0) == testName }

            if !hasFinished {
                return started
            }
        }

        return nil
    }

    /// Extract a stable test name from a test output line for matching started/finished pairs.
    private static func extractTestName(from line: String) -> String {
        // XCTest: "Test Case '-[MyTests testFoo]' started/passed/failed"
        if let quoteStart = line.firstIndex(of: "'"),
           let quoteEnd = line[line.index(after: quoteStart)...].firstIndex(of: "'") {
            return String(line[quoteStart ... quoteEnd])
        }
        // Swift Testing: "Test someTest() started/passed/failed after..."
        // Gradle: "com.example.MyTest > testSomething STARTED"
        // Strip status words to get a comparable identifier
        return line
            .replacingOccurrences(of: " started.", with: "")
            .replacingOccurrences(of: " started", with: "")
            .replacingOccurrences(of: " STARTED", with: "")
            .replacingOccurrences(of: " passed.", with: "")
            .replacingOccurrences(of: " failed.", with: "")
            .components(separatedBy: " passed after").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            ?? line
    }

    /// Count tests that completed (passed or failed).
    public static func countCompletedTests(lines: [String]) -> Int {
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // XCTest: "Test Case '-[Suite test]' passed/failed (X seconds)."
            // Check XCTest first — it's more specific and should not also match the generic pattern
            if trimmed.contains("Test Case '"), trimmed.contains("passed") || trimmed.contains("failed") {
                count += 1
            }
            // Swift Testing: "Test foo() passed/failed after X seconds."
            else if trimmed.hasPrefix("Test "), !trimmed.hasPrefix("Test run with"),
                    trimmed.contains(" passed") || trimmed.contains(" failed") {
                count += 1
            }
        }
        return count
    }

    /// Extract failing test names and error lines from test output.
    public static func extractFailingTests(lines: [String]) -> [String] {
        var failures: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Swift Testing failures
            if (trimmed.contains("Test ") && trimmed.contains(" failed after"))
                || trimmed.contains("Expectation failed")
                || trimmed.contains("expectation failed")
                || trimmed.contains("Issue recorded") {
                failures.append(trimmed)
            }

            // XCTest failures
            if trimmed.contains("Test Case '"), trimmed.contains(" failed") {
                failures.append(trimmed)
            }

            // Gradle test failures
            if trimmed.contains("FAILED"), trimmed.contains(">") || trimmed.contains("Test ") {
                failures.append(trimmed)
            }
        }

        return failures
    }

    /// Extract error/build failure lines.
    public static func extractErrors(lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                $0.contains("error:")
                    || $0.contains("** TEST FAILED **")
                    || $0.contains("BUILD FAILED")
            }
    }

    /// Reasons a test runner can exit with a non-zero status without an actual
    /// test failure. The pre-push hook treats these as "nothing to run" so they
    /// don't block a push.
    public enum NoOpExitReason: Equatable, Sendable {
        /// `xcodebuild test -scheme X` exits 65 with this message when X has no
        /// Testables. Happens when nested SwiftPM packages own the tests and the
        /// app scheme has no inline test target.
        case noTestBundlesAvailable
        /// `xcodebuild test -scheme X` exits 65 with this message when X has a
        /// TestAction with no Testables block. Same intent as the above.
        case schemeTestActionNotConfigured

        public var humanDescription: String {
            switch self {
            case .noTestBundlesAvailable:
                "the scheme exposes no test bundles"
            case .schemeTestActionNotConfigured:
                "the scheme has no test action configured"
            }
        }
    }

    /// Inspect test runner output and return a no-op reason if the runner exited
    /// non-zero but didn't actually fail any test. Currently scoped to xcodebuild;
    /// `swift test` and `gradle test` propagate compile/test failures directly.
    public static func detectNoOpExitReason(lines: [String]) -> NoOpExitReason? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("There are no test bundles available to test") {
                return .noTestBundlesAvailable
            }
            if trimmed.contains("is not currently configured for the test action") {
                return .schemeTestActionNotConfigured
            }
        }
        return nil
    }

    /// Extract the test run summary line (if any).
    public static func extractTestSummary(lines: [String]) -> String? {
        // Swift Testing: "Test run with 42 tests passed after 1.234 seconds."
        let swiftTestingSummary = lines
            .last { $0.contains("Test run with") && $0.contains("passed") }

        // XCTest: "Executed 12 tests, with 0 failures ..."
        let xcTestSummary = lines
            .last { $0.contains("Executed ") && $0.contains(" tests") }

        // Gradle: "BUILD SUCCESSFUL in Xs"
        let gradleSummary = lines
            .last { $0.contains("BUILD SUCCESSFUL") }

        return swiftTestingSummary
            ?? xcTestSummary.flatMap { $0.contains("Executed 0 tests") ? nil : $0 }
            ?? gradleSummary
    }
}
