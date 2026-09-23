import Foundation
import GitHooksCore
import Testing

struct HookRepairTests {
    /// A hook as project-hooks 1.0 generated it, with the repository-local candidate.
    private static let outdatedHook = """
        #!/usr/bin/env bash
        set -euo pipefail

        HOOK_NAME="$(basename "$0")"
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

        BIN=""
        for candidate in \\
          "${REPO_ROOT:+$REPO_ROOT/.build/release/project-hooks}" \\
          '/opt/tools/project-hooks' \\  "$HOME/.local/bin/project-hooks" \\
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

    private static let foreignHook = "#!/bin/sh\nexec lint-staged\n"

    @Test
    func `repair replaces generated hooks and keeps hooks from other tools`() throws {
        let hooksDir = try makeHooksDirectory(preCommit: Self.outdatedHook, prePush: Self.foreignHook)
        defer { removeScratch(containing: hooksDir) }

        let results = try HookInstaller.repairHooks(in: hooksDir, binaryPath: "/opt/tools/project-hooks")

        #expect(results.map(\.outcome) == [.outdated, .foreign])
        let expected = HookInstaller.hookScript(binaryPath: "/opt/tools/project-hooks")
        #expect(try contents(of: "pre-commit", in: hooksDir) == expected)
        #expect(try contents(of: "pre-push", in: hooksDir) == Self.foreignHook)
        let permissions = try FileManager.default.attributesOfItem(atPath: "\(hooksDir)/pre-commit")[.posixPermissions]
        #expect(permissions as? Int == 0o755)
    }

    @Test
    func `repair twice changes nothing the second time`() throws {
        let hooksDir = try makeHooksDirectory(preCommit: Self.outdatedHook, prePush: Self.outdatedHook)
        defer { removeScratch(containing: hooksDir) }

        _ = try HookInstaller.repairHooks(in: hooksDir, binaryPath: "/opt/tools/project-hooks")
        let second = try HookInstaller.repairHooks(in: hooksDir, binaryPath: "/opt/tools/project-hooks")

        #expect(second.map(\.outcome) == [.current, .current])
    }

    @Test
    func `dry run reports outdated hooks without writing`() throws {
        let hooksDir = try makeHooksDirectory(preCommit: Self.outdatedHook, prePush: nil)
        defer { removeScratch(containing: hooksDir) }

        let results = try HookInstaller.repairHooks(in: hooksDir, binaryPath: "/opt/tools/project-hooks", dryRun: true)

        #expect(results.map(\.outcome) == [.outdated, .missing])
        #expect(try contents(of: "pre-commit", in: hooksDir) == Self.outdatedHook)
        #expect(!FileManager.default.fileExists(atPath: "\(hooksDir)/pre-push"))
    }

    @Test
    func `a different binary path makes a current hook outdated`() throws {
        let hooksDir = try makeHooksDirectory(
            preCommit: HookInstaller.hookScript(binaryPath: "/old/project-hooks"),
            prePush: nil,
        )
        defer { removeScratch(containing: hooksDir) }

        let results = try HookInstaller.repairHooks(in: hooksDir, binaryPath: "/new/project-hooks")

        #expect(results.first?.outcome == .outdated)
        #expect(try contents(of: "pre-commit", in: hooksDir).contains("/new/project-hooks"))
    }

    @Test(arguments: [outdatedHook, HookInstaller.hookScript(binaryPath: "/opt/tools/project-hooks")])
    func `generated hooks of every version are recognized`(script: String) {
        #expect(HookInstaller.isGeneratedHook(script))
    }

    @Test
    func `other tools' hooks are not recognized as generated`() {
        #expect(!HookInstaller.isGeneratedHook(Self.foreignHook))
    }

    private func makeHooksDirectory(preCommit: String?, prePush: String?) throws -> String {
        let hooksDir = try makeTempDir(prefix: "repair").appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for (name, script) in [("pre-commit", preCommit), ("pre-push", prePush)] {
            guard let script else { continue }
            try script.write(to: hooksDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return hooksDir.path
    }

    private func removeScratch(containing hooksDir: String) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: hooksDir).deletingLastPathComponent())
    }

    private func contents(of hook: String, in hooksDir: String) throws -> String {
        try String(contentsOfFile: "\(hooksDir)/\(hook)", encoding: .utf8)
    }
}
