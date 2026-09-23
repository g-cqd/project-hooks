import Foundation
import Testing

@testable import GitHooksCLI

struct CommandRunnerTests {
    /// Review finding PH-9: every command waited at least 0.5 s before its first check, so a hook that runs dozens of
    /// git commands spent seconds sleeping.
    @Test
    func `a quick command returns without a fixed wait`() throws {
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<5 {
            let result = try runCommand(["/usr/bin/true"])
            #expect(result.exitCode == 0)
        }
        let elapsed = clock.now - started

        // Five commands under the old 0.5 s wait took at least 2.5 s.
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    @Test
    func `a command that outlives its timeout is stopped`() throws {
        let result = try runCommand(["/bin/sh", "-c", "exec /bin/sleep 30"], timeoutSeconds: 0.2)

        #expect(result.timedOut)
        #expect(result.exitCode == -1)
    }

    @Test
    func `output and exit status come back`() throws {
        let result = try runCommand(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"])

        #expect(result.exitCode == 3)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
        #expect(!result.timedOut)
    }
}
