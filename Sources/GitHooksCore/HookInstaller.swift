import Foundation

/// Generates hook scripts and handles installation logic.
public enum HookInstaller {
    public static let hookNames = ["pre-commit", "pre-push"]

    /// Generate the hook script content that delegates to the project-hooks binary.
    public static func hookScript(binaryPath: String? = nil) -> String {
        let binaryCandidate = if let binaryPath {
            """
              \(shellQuoted(binaryPath)) \\
            """
        } else {
            ""
        }

        return """
        #!/usr/bin/env bash
        set -euo pipefail

        HOOK_NAME="$(basename "$0")"
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

        BIN=""
        for candidate in \\
          "${REPO_ROOT:+$REPO_ROOT/.build/release/project-hooks}" \\
        \(binaryCandidate)  "$HOME/.local/bin/project-hooks" \\
          "$(command -v project-hooks 2>/dev/null || true)"; do
          if [[ -n "$candidate" && -x "$candidate" ]]; then
            BIN="$candidate"
            break
          fi
        done

        if [[ -z "$BIN" ]]; then
          echo "[ERROR] project-hooks binary not found." >&2
          echo "[INFO] Install with: swift build -c release" >&2
          exit 1
        fi

        exec "$BIN" "$HOOK_NAME" "$@"
        """
    }

    /// Write hook scripts to a hooks directory.
    /// - Parameters:
    ///   - hooksDir: Path to the hooks directory (e.g. `.git/hooks` or `~/.git-templates/hooks`)
    ///   - binaryPath: Optional explicit path to the project-hooks binary to embed in the script
    /// - Returns: List of installed hook file paths.
    public static func installHooks(
        to hooksDir: String,
        binaryPath: String? = nil,
    ) throws -> [String] {
        let fm = FileManager.default
        let script = hookScript(binaryPath: binaryPath)

        // Create hooks directory if needed
        if !fm.fileExists(atPath: hooksDir) {
            try fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }

        var installed: [String] = []
        for hook in hookNames {
            let hookPath = URL(fileURLWithPath: hooksDir).appendingPathComponent(hook).path
            try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
            installed.append(hookPath)
        }

        return installed
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
