import Foundation
import GitHooksCore

// MARK: - Test output diagnosis

private func printTimeoutDiagnosis(lines: [String], moduleName: String, timeout: TimeInterval) {
    printError("Tests timed out after \(Int(timeout))s for \(moduleName).")
    if let lastStarted = TestOutputParser.findLastStartedTest(lines: lines) {
        printError("Likely hanging on: \(lastStarted)")
    }
    let completedCount = TestOutputParser.countCompletedTests(lines: lines)
    if completedCount > 0 {
        printInfo("\(completedCount) test(s) completed before timeout.")
    }
    printInfo("Last output before timeout:")
    for line in lines.suffix(30) {
        print("  \(line)")
    }
    printWarn("Possible causes: deadlock, infinite loop, network wait, or slow test.")
    printWarn("Increase timeout: export GITHOOKS_TEST_TIMEOUT_SECONDS=<seconds>")
}

private func printSuccessDiagnosis(lines: [String], moduleName: String) {
    let summary = TestOutputParser.extractTestSummary(lines: lines)
    if let summary {
        printOK("Tests passed (\(moduleName)). \(summary.trimmingCharacters(in: .whitespaces))")
    } else {
        printOK("Tests passed (\(moduleName)).")
    }
}

private func printFailureDiagnosis(lines: [String], moduleName: String) {
    let failingTests = TestOutputParser.extractFailingTests(lines: lines)
    let errorLines = TestOutputParser.extractErrors(lines: lines)

    printError("Tests failed (\(moduleName)).")

    if !failingTests.isEmpty {
        printInfo("Failing tests (\(failingTests.count)):")
        for test in failingTests.prefix(40) {
            print("  \(test)")
        }
        if failingTests.count > 40 {
            printWarn("... and \(failingTests.count - 40) more.")
        }
    }

    if !errorLines.isEmpty {
        printInfo("Errors:")
        for line in errorLines.suffix(40) {
            print("  \(line)")
        }
    }

    if failingTests.isEmpty, errorLines.isEmpty {
        printWarn("No specific failure lines detected. Last output:")
        for line in lines.suffix(30) {
            print("  \(line)")
        }
    }

    printWarn("Push blocked. Fix failing tests and push again.")
}

/// Outcome of a test runner invocation as interpreted by the diagnosis layer.
///
/// Distinguishes "this module has no tests to run" (soft no-op, push proceeds)
/// from "tests actually failed" (hard fail, push blocked).
enum TestRunOutcome: Equatable {
    case passed
    case timedOut
    case failed
    /// Non-zero exit, but the runner didn't actually fail a test. The push
    /// pipeline should print an info line and continue. Currently fires for
    /// xcodebuild when the scheme has no Testables / no test action wired.
    case noOp(TestOutputParser.NoOpExitReason)
}

/// Analyze test output and print a diagnosis of what failed, hung, or no-op'd.
@discardableResult
func diagnoseTestResult(
    _ result: CommandResult,
    moduleName: String,
    timeout: TimeInterval,
) -> TestRunOutcome {
    let lines = result.combinedText
        .split(whereSeparator: \.isNewline)
        .map(String.init)

    if result.timedOut {
        printTimeoutDiagnosis(lines: lines, moduleName: moduleName, timeout: timeout)
        return .timedOut
    }

    if result.exitCode == 0 {
        printSuccessDiagnosis(lines: lines, moduleName: moduleName)
        return .passed
    }

    if let reason = TestOutputParser.detectNoOpExitReason(lines: lines) {
        printInfo("No-op test stage (\(moduleName)): \(reason.humanDescription). Continuing.")
        return .noOp(reason)
    }

    printFailureDiagnosis(lines: lines, moduleName: moduleName)
    return .failed
}
