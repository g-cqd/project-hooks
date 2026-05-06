import GitHooksCore
import Testing

struct EnvDiscoveryTests {
    // MARK: - Java

    @Test
    func `existing valid JAVA_HOME returns nil so we don't overwrite`() {
        let result = EnvDiscovery.discoverJavaHome(
            currentEnv: ["JAVA_HOME": "/opt/jdk"],
            candidates: [],
            isExecutable: { $0 == "/opt/jdk/bin/java" },
            runJavaHome: { nil },
        )
        #expect(result == nil)
    }

    @Test
    func `JAVA_HOME pointing to a missing JDK is ignored and we fall through`() {
        let result = EnvDiscovery.discoverJavaHome(
            currentEnv: ["JAVA_HOME": "/nonexistent"],
            candidates: ["/opt/jdk"],
            isExecutable: { $0 == "/opt/jdk/bin/java" },
            runJavaHome: { nil },
        )
        #expect(result == "/opt/jdk")
    }

    @Test
    func `system java home wins over candidate list`() {
        let result = EnvDiscovery.discoverJavaHome(
            currentEnv: [:],
            candidates: ["/opt/jdk"],
            isExecutable: { $0 == "/system-jdk/bin/java" || $0 == "/opt/jdk/bin/java" },
            runJavaHome: { "/system-jdk" },
        )
        #expect(result == "/system-jdk")
    }

    @Test
    func `system java home rejected if path doesn't actually have a java binary`() {
        let result = EnvDiscovery.discoverJavaHome(
            currentEnv: [:],
            candidates: ["/opt/jdk"],
            isExecutable: { $0 == "/opt/jdk/bin/java" },
            runJavaHome: { "/garbage" },
        )
        #expect(result == "/opt/jdk")
    }

    @Test
    func `falls back to first matching candidate`() {
        let result = EnvDiscovery.discoverJavaHome(
            currentEnv: [:],
            candidates: ["/no", "/yes", "/also-yes"],
            isExecutable: { $0 == "/yes/bin/java" || $0 == "/also-yes/bin/java" },
            runJavaHome: { nil },
        )
        #expect(result == "/yes")
    }

    @Test
    func `returns nil when no JDK can be found anywhere`() {
        let result = EnvDiscovery.discoverJavaHome(
            currentEnv: [:],
            candidates: ["/a", "/b"],
            isExecutable: { _ in false },
            runJavaHome: { nil },
        )
        #expect(result == nil)
    }

    @Test
    func `default candidate list includes Android Studio JBR`() {
        // Sanity check: the default list mentions both Homebrew openjdk and Android Studio JBR.
        let candidates = EnvDiscovery.defaultJavaHomeCandidates
        #expect(candidates.contains { $0.contains("/opt/homebrew/opt/openjdk") })
        #expect(candidates.contains { $0.contains("Android Studio.app") })
    }

    // MARK: - Android SDK

    @Test
    func `existing ANDROID_HOME returns nil`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: ["ANDROID_HOME": "/some/sdk"],
            candidates: [],
            directoryExists: { $0 == "/some/sdk" },
        )
        #expect(result == nil)
    }

    @Test
    func `existing ANDROID_SDK_ROOT also blocks discovery`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: ["ANDROID_SDK_ROOT": "/another/sdk"],
            candidates: [],
            directoryExists: { $0 == "/another/sdk" },
        )
        #expect(result == nil)
    }

    @Test
    func `falls through when env points to a non-existent dir`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: ["ANDROID_HOME": "/nope"],
            candidates: ["/found"],
            directoryExists: { $0 == "/found" },
        )
        #expect(result == "/found")
    }

    @Test
    func `expands HOME variable in candidates`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: [:],
            homeDir: "/Users/test",
            candidates: ["$HOME/Library/Android/sdk"],
            directoryExists: { $0 == "/Users/test/Library/Android/sdk" },
        )
        #expect(result == "/Users/test/Library/Android/sdk")
    }

    @Test
    func `expands tilde in candidates`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: [:],
            homeDir: "/Users/test",
            candidates: ["~/sdk"],
            directoryExists: { $0 == "/Users/test/sdk" },
        )
        #expect(result == "/Users/test/sdk")
    }

    @Test
    func `picks first matching candidate in order`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: [:],
            homeDir: "/h",
            candidates: ["/a", "/b", "/c"],
            directoryExists: { $0 == "/b" || $0 == "/c" },
        )
        #expect(result == "/b")
    }

    @Test
    func `returns nil when no SDK found`() {
        let result = EnvDiscovery.discoverAndroidSdk(
            currentEnv: [:],
            candidates: ["/a", "/b"],
            directoryExists: { _ in false },
        )
        #expect(result == nil)
    }
}
