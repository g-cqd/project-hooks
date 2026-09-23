import Foundation
import Synchronization
import Testing

@testable import GitHooksCLI

/// Review finding PH-10: every command recomputed the environment, and so ran `/usr/libexec/java_home` when
/// `JAVA_HOME` was unset, before each of the dozens of git commands that a hook runs.
struct ChildEnvironmentTests {
    private final class Counter: Sendable {
        let value = Atomic<Int>(0)
    }

    private static let toolchains = ChildEnvironment.Toolchains(
        variables: ["JAVA_HOME": "/jdk", "ANDROID_HOME": "/sdk"],
        pathPrefix: ["/jdk/bin"],
    )

    @Test
    func `toolchain discovery runs once, and never for git`() {
        let discoveries = Counter()
        let environment = ChildEnvironment(parent: ["PATH": "/usr/bin:/bin"]) { _ in
            discoveries.value.add(1, ordering: .relaxed)
            return Self.toolchains
        }

        for _ in 0..<3 {
            _ = environment.environment(for: ["git", "status"])
        }
        let beforeOtherCommands = discoveries.value.load(ordering: .relaxed)
        let gradle = environment.environment(for: ["/repo/gradlew", "test"])
        let ktlint = environment.environment(for: ["/opt/homebrew/bin/ktlint"])

        #expect(beforeOtherCommands == 0)
        #expect(discoveries.value.load(ordering: .relaxed) == 1)
        #expect(gradle["JAVA_HOME"] == "/jdk")
        #expect(gradle == ktlint)
    }

    @Test
    func `commands find package managers' binaries, and other commands the JDK first`() {
        let environment = ChildEnvironment(parent: ["PATH": "/usr/bin:/bin"]) { _ in Self.toolchains }

        let git = environment.environment(for: ["/usr/bin/git", "log"])
        let gradle = environment.environment(for: ["gradle", "test"])

        #expect(git["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin")
        #expect(git["JAVA_HOME"] == nil)
        #expect(gradle["PATH"] == "/jdk/bin:" + (git["PATH"] ?? ""))
    }

    @Test
    func `removed variables go, and overrides win`() {
        let environment = ChildEnvironment(parent: ["PATH": "/usr/bin", "GIT_DIR": "/elsewhere", "LANG": "C"]) { _ in
            Self.toolchains
        }

        let result = environment.environment(
            for: ["swift", "test"],
            removing: ["GIT_DIR"],
            overrides: ["LANG": "en_US.UTF-8", "JAVA_HOME": "/other-jdk"],
        )

        #expect(result["GIT_DIR"] == nil)
        #expect(result["LANG"] == "en_US.UTF-8")
        #expect(result["JAVA_HOME"] == "/other-jdk")
    }
}
