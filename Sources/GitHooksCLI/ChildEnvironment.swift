import Foundation
import GitHooksCore
import Synchronization

/// The environment that commands start with.
///
/// It is this process's environment with the package managers' binary directories on `PATH`. Commands other than git
/// also get a JDK and an Android SDK when the environment lacks them, for Gradle and the JVM-based linters. Finding
/// them can run `/usr/libexec/java_home`, so it happens at most once per process, and never for git, which a hook runs
/// dozens of times.
final class ChildEnvironment: Sendable {
    /// A JDK and an Android SDK: variables to set, and directories to put first on `PATH`.
    struct Toolchains: Equatable {
        var variables: [String: String] = [:]
        var pathPrefix: [String] = []
    }

    static let shared = ChildEnvironment(parent: ProcessInfo.processInfo.environment)

    private let parent: [String: String]
    private let discoverToolchains: @Sendable ([String: String]) -> Toolchains
    private let toolchains = Mutex<Toolchains?>(nil)

    /// - Parameters:
    ///   - parent: The environment to start from.
    ///   - discoverToolchains: Finds the JDK and the Android SDK for `parent`. Called at most once.
    init(
        parent: [String: String],
        discoverToolchains: @escaping @Sendable ([String: String]) -> Toolchains = ChildEnvironment
            .discoverJVMToolchains,
    ) {
        self.parent = parent
        self.discoverToolchains = discoverToolchains
    }

    /// The environment for `command`, without the `removed` variables, and with `overrides` applied last.
    func environment(
        for command: [String],
        removing removed: Set<String> = [],
        overrides: [String: String]? = nil,
    ) -> [String: String] {
        var environment = parent
        for key in removed {
            environment.removeValue(forKey: key)
        }

        var path = EnvDiscovery.pathPreferringPackageManagers(environment["PATH"] ?? "")
        if !Self.isGit(command) {
            let found = toolchains.withLock { cached in
                if let cached { return cached }
                let found = discoverToolchains(parent)
                cached = found
                return found
            }
            environment.merge(found.variables) { _, discovered in discovered }
            let entries = path.split(separator: ":").map(String.init)
            path = (found.pathPrefix.filter { !entries.contains($0) } + entries).joined(separator: ":")
        }
        environment["PATH"] = path

        if let overrides {
            environment.merge(overrides) { _, override in override }
        }
        return environment
    }

    /// A JDK when `JAVA_HOME` is missing or invalid, so that Gradle and xcodebuild do not stop at macOS's
    /// `/usr/bin/java` stub, and an Android SDK when neither `ANDROID_HOME` nor `ANDROID_SDK_ROOT` names one.
    static func discoverJVMToolchains(_ environment: [String: String]) -> Toolchains {
        var toolchains = Toolchains()
        if let javaHome = EnvDiscovery.discoverJavaHome(currentEnv: environment) {
            toolchains.variables["JAVA_HOME"] = javaHome
            toolchains.pathPrefix.append("\(javaHome)/bin")
        }
        if let androidSdk = EnvDiscovery.discoverAndroidSdk(currentEnv: environment) {
            toolchains.variables["ANDROID_HOME"] = androidSdk
            toolchains.variables["ANDROID_SDK_ROOT"] = androidSdk
        }
        return toolchains
    }

    private static func isGit(_ command: [String]) -> Bool {
        command.first.map { URL(fileURLWithPath: $0).lastPathComponent == "git" } ?? false
    }
}
