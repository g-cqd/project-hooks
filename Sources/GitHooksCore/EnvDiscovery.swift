import Foundation

/// Discovers JDK and Android SDK locations to inject into subprocess environments.
///
/// macOS in particular ships `/usr/bin/java` as a stub that requires either a system-registered
/// JDK or `JAVA_HOME`. Homebrew's `openjdk` formulas are unlinked by default to avoid clashing
/// with that stub, so users frequently end up with Java installed but invisible to subprocesses
/// like gradle. This module probes common locations so project-hooks can transparently set
/// `JAVA_HOME` and `ANDROID_HOME` when missing.
public enum EnvDiscovery {
    /// Default Homebrew + Android Studio paths to probe for a JDK installation.
    /// Order matters: unversioned formulas first, then descending major versions, then
    /// Android Studio's bundled runtimes as a last resort.
    public static let defaultJavaHomeCandidates: [String] = [
        "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk@8/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/usr/local/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home",
        "/Library/Java/JavaVirtualMachines/openjdk.jdk/Contents/Home",
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        "/Applications/Android Studio.app/Contents/jre/Contents/Home",
    ]

    /// Default Android SDK locations. The macOS Android Studio default installs to
    /// `~/Library/Android/sdk`. Linux and command-line installations vary.
    public static let defaultAndroidSdkCandidates: [String] = [
        "$HOME/Library/Android/sdk",
        "$HOME/Android/sdk",
        "/opt/homebrew/share/android-commandlinetools",
        "/usr/local/share/android-commandlinetools",
        "/opt/android-sdk",
    ]

    /// Resolve a JDK home to inject as `JAVA_HOME`, or nil when nothing should change.
    ///
    /// - The current `JAVA_HOME`, if set and pointing at a valid JDK, is preserved (returns nil).
    /// - Otherwise tries `runJavaHome` (typically `/usr/libexec/java_home`), then probes
    ///   `candidates` in order, returning the first that contains an executable `bin/java`.
    public static func discoverJavaHome(
        currentEnv: [String: String],
        candidates: [String] = defaultJavaHomeCandidates,
        isExecutable: (String) -> Bool = Self.defaultIsExecutable,
        runJavaHome: () -> String? = Self.runSystemJavaHome,
    ) -> String? {
        if let existing = currentEnv["JAVA_HOME"], !existing.isEmpty {
            // Trust an existing JAVA_HOME if it actually points to a JDK; otherwise fall through.
            if isExecutable("\(existing)/bin/java") {
                return nil
            }
        }

        if let systemPath = runJavaHome(),
           !systemPath.isEmpty,
           isExecutable("\(systemPath)/bin/java") {
            return systemPath
        }

        for candidate in candidates where isExecutable("\(candidate)/bin/java") {
            return candidate
        }

        return nil
    }

    /// Resolve an Android SDK location, or nil when nothing should change.
    ///
    /// Preserves `ANDROID_HOME` / `ANDROID_SDK_ROOT` if either is set to an existing directory.
    /// Otherwise probes `candidates`, expanding a leading `$HOME` against `homeDir`.
    public static func discoverAndroidSdk(
        currentEnv: [String: String],
        homeDir: String = NSHomeDirectory(),
        candidates: [String] = defaultAndroidSdkCandidates,
        directoryExists: (String) -> Bool = Self.defaultDirectoryExists,
    ) -> String? {
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let existing = currentEnv[key], !existing.isEmpty, directoryExists(existing) {
                return nil
            }
        }

        for candidate in candidates {
            let expanded = expandHomeDir(candidate, homeDir: homeDir)
            if directoryExists(expanded) {
                return expanded
            }
        }

        return nil
    }

    // MARK: - Helpers

    static func expandHomeDir(_ path: String, homeDir: String) -> String {
        if path == "$HOME" { return homeDir }
        if path.hasPrefix("$HOME/") {
            return homeDir + String(path.dropFirst("$HOME".count))
        }
        if path == "~" { return homeDir }
        if path.hasPrefix("~/") {
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }

    public static func defaultIsExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Invoke `/usr/libexec/java_home` and return its trimmed stdout when it succeeds.
    /// Silently returns nil on macOS systems with no system-registered JDK.
    public static func runSystemJavaHome() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}
