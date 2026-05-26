import Foundation

/// Pure helpers for routing Swift / xcodebuild build artifacts into an isolated scratch dir.
///
/// The lifecycle (create + remove) lives in the CLI runner; this module only shapes the
/// command so the logic is unit-testable without filesystem fixtures.
public enum BuildIsolation {
    /// Augment a build/test command with the tool-specific flag that redirects its
    /// intermediates into `scratchPath`.
    ///
    /// Returns the command unchanged when the tool isn't recognised or when the caller
    /// already specified the relevant flag — an explicit override at the call site wins so
    /// callers can opt out of isolation by passing the flag themselves.
    public static func inject(into command: [String], scratchPath: String) -> [String] {
        guard let tool = command.first else { return command }
        switch tool {
            case "xcodebuild":
                guard !command.contains("-derivedDataPath") else { return command }
                return command + ["-derivedDataPath", scratchPath]
            case "swift":
                guard !command.contains("--scratch-path"), !command.contains("--build-path") else {
                    return command
                }
                return command + ["--scratch-path", scratchPath]
            default:
                // Gradle and other tools are passed through unchanged — gradle's build dir
                // is configured per-project via -Dorg.gradle.project.buildDir at the call
                // site rather than via a tool-level flag, so it doesn't fit this pattern.
                return command
        }
    }
}
