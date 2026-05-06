import GitHooksCore
import Testing

struct TestOutputParserTests {
    // MARK: - findLastStartedTest

    @Test
    func `find last started test detects hung swift test`() {
        let lines = [
            "Test someSetup() passed after 0.001 seconds.",
            "Test longRunningTest() started.",
        ]
        let result = TestOutputParser.findLastStartedTest(lines: lines)
        #expect(result != nil)
        #expect(result?.contains("longRunningTest") == true)
    }

    @Test
    func `find last started test detects hung XC test`() {
        let lines = [
            "Test Case '-[MyTests testFast]' started.",
            "Test Case '-[MyTests testFast]' passed (0.001 seconds).",
            "Test Case '-[MyTests testSlow]' started.",
        ]
        let result = TestOutputParser.findLastStartedTest(lines: lines)
        #expect(result != nil)
        #expect(result?.contains("testSlow") == true)
    }

    @Test
    func `find last started test returns nil when all finished`() {
        let lines = [
            "Test foo() started.",
            "Test foo() passed after 0.1 seconds.",
            "Test bar() started.",
            "Test bar() passed after 0.2 seconds.",
        ]
        // All tests finished — no hung test
        let result = TestOutputParser.findLastStartedTest(lines: lines)
        #expect(result == nil)
    }

    @Test
    func `find last started test returns nil for empty input`() {
        #expect(TestOutputParser.findLastStartedTest(lines: []) == nil)
    }

    @Test
    func `find last started test detects gradle started`() {
        let lines = [
            "com.example.MyTest > testSomething STARTED",
        ]
        let result = TestOutputParser.findLastStartedTest(lines: lines)
        #expect(result != nil)
        #expect(result?.contains("testSomething") == true)
    }

    // MARK: - countCompletedTests

    @Test
    func `count completed tests with swift testing output`() {
        let lines = [
            "Test foo() passed after 0.1 seconds.",
            "Test bar() failed after 0.2 seconds.",
            "Test baz() passed after 0.05 seconds.",
        ]
        #expect(TestOutputParser.countCompletedTests(lines: lines) == 3)
    }

    @Test
    func `count completed tests with XC test output`() {
        let lines = [
            "Test Case '-[MyTests testA]' passed (0.001 seconds).",
            "Test Case '-[MyTests testB]' failed (0.500 seconds).",
        ]
        #expect(TestOutputParser.countCompletedTests(lines: lines) == 2)
    }

    @Test
    func `count completed tests excludes summary line`() {
        let lines = [
            "Test foo() passed after 0.1 seconds.",
            "Test run with 1 test in 1 suite passed after 0.1 seconds.",
        ]
        // The summary line should NOT be counted as a completed test
        #expect(TestOutputParser.countCompletedTests(lines: lines) == 1)
    }

    @Test
    func `count completed tests returns zero for empty input`() {
        #expect(TestOutputParser.countCompletedTests(lines: []) == 0)
    }

    @Test
    func `count completed tests with mixed frameworks`() {
        let lines = [
            "Test foo() passed after 0.1 seconds.",
            "Test Case '-[Suite testBar]' passed (0.1 seconds).",
            "Test baz() failed after 0.3 seconds.",
        ]
        #expect(TestOutputParser.countCompletedTests(lines: lines) == 3)
    }

    // MARK: - extractFailingTests

    @Test
    func `extract failing tests from swift testing`() {
        let lines = [
            "Test foo() passed after 0.1 seconds.",
            "Test bar() failed after 0.5 seconds.",
            "Expectation failed: expected true, got false",
            "Issue recorded at SourceFile.swift:42",
        ]
        let failures = TestOutputParser.extractFailingTests(lines: lines)
        #expect(failures.count == 3)
        #expect(failures[0].contains("bar"))
        #expect(failures[1].contains("Expectation failed"))
        #expect(failures[2].contains("Issue recorded"))
    }

    @Test
    func `extract failing tests from XC test`() {
        let lines = [
            "Test Case '-[MyTests testA]' passed (0.001 seconds).",
            "Test Case '-[MyTests testB]' failed (0.500 seconds).",
        ]
        let failures = TestOutputParser.extractFailingTests(lines: lines)
        #expect(failures.count == 1)
        #expect(failures[0].contains("testB"))
    }

    @Test
    func `extract failing tests from gradle`() {
        let lines = [
            "> Task :app:test",
            "com.example.MyTest > testSomething FAILED",
            "BUILD FAILED in 5s",
        ]
        let failures = TestOutputParser.extractFailingTests(lines: lines)
        #expect(failures.count == 1)
        #expect(failures[0].contains("testSomething"))
    }

    @Test
    func `extract failing tests returns empty when all pass`() {
        let lines = [
            "Test foo() passed after 0.1 seconds.",
            "Test bar() passed after 0.2 seconds.",
        ]
        #expect(TestOutputParser.extractFailingTests(lines: lines).isEmpty)
    }

    // MARK: - extractErrors

    @Test
    func `extract errors from swift compilation`() {
        let lines = [
            "Building for debugging...",
            "/path/to/File.swift:10:5: error: cannot find 'foo' in scope",
            "Build complete!",
        ]
        let errors = TestOutputParser.extractErrors(lines: lines)
        #expect(errors.count == 1)
        #expect(errors[0].contains("cannot find"))
    }

    @Test
    func `extract errors from xcodebuild test failed`() {
        let lines = [
            "** TEST FAILED **",
        ]
        let errors = TestOutputParser.extractErrors(lines: lines)
        #expect(errors.count == 1)
    }

    @Test
    func `extract errors from gradle build failed`() {
        let lines = [
            "BUILD FAILED in 10s",
        ]
        let errors = TestOutputParser.extractErrors(lines: lines)
        #expect(errors.count == 1)
    }

    @Test
    func `extract errors returns empty for clean output`() {
        let lines = [
            "Building for debugging...",
            "Build complete!",
            "Test run with 5 tests passed.",
        ]
        #expect(TestOutputParser.extractErrors(lines: lines).isEmpty)
    }

    // MARK: - extractTestSummary

    @Test
    func `extract test summary from swift testing`() {
        let lines = [
            "Test foo() passed after 0.1 seconds.",
            "Test run with 42 tests in 5 suites passed after 1.234 seconds.",
        ]
        let summary = TestOutputParser.extractTestSummary(lines: lines)
        #expect(summary?.contains("42 tests") == true)
    }

    @Test
    func `extract test summary from XC test`() {
        let lines = [
            "Executed 12 tests, with 0 failures (0 unexpected) in 1.5 seconds",
        ]
        let summary = TestOutputParser.extractTestSummary(lines: lines)
        #expect(summary?.contains("12 tests") == true)
    }

    @Test
    func `extract test summary skips XC test with zero tests`() {
        let lines = [
            "Executed 0 tests, with 0 failures (0 unexpected) in 0.0 seconds",
        ]
        // Zero tests executed should return nil (not a meaningful summary)
        #expect(TestOutputParser.extractTestSummary(lines: lines) == nil)
    }

    @Test
    func `extract test summary from gradle`() {
        let lines = [
            "BUILD SUCCESSFUL in 15s",
        ]
        let summary = TestOutputParser.extractTestSummary(lines: lines)
        #expect(summary?.contains("BUILD SUCCESSFUL") == true)
    }

    @Test
    func `extract test summary prefers swift testing over XC test`() {
        let lines = [
            "Executed 0 tests, with 0 failures (0 unexpected) in 0.0 seconds",
            "Test run with 5 tests in 2 suites passed after 0.5 seconds.",
        ]
        let summary = TestOutputParser.extractTestSummary(lines: lines)
        #expect(summary?.contains("5 tests") == true)
    }

    @Test
    func `extract test summary returns nil for no summary`() {
        let lines = ["Just some random output"]
        #expect(TestOutputParser.extractTestSummary(lines: lines) == nil)
    }
}
