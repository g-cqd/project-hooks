import Foundation
import GitHooksCore
import Testing

struct HookInstallerTests {
    @Test
    func `hook names contains expected hooks`() {
        #expect(HookInstaller.hookNames.contains("pre-commit"))
        #expect(HookInstaller.hookNames.contains("pre-push"))
    }

    @Test
    func `hook script contains shebang`() {
        let script = HookInstaller.hookScript()
        #expect(script.hasPrefix("#!/usr/bin/env bash"))
    }

    @Test
    func `hook script derives hook name from basename`() {
        let script = HookInstaller.hookScript()
        #expect(script.contains("HOOK_NAME=\"$(basename \"$0\")\""))
    }

    @Test
    func `hook script searches for binary in standard locations`() {
        let script = HookInstaller.hookScript()
        #expect(script.contains(".build/release/project-hooks"))
        #expect(script.contains(".local/bin/project-hooks"))
        #expect(script.contains("command -v project-hooks"))
    }

    @Test
    func `hook script embeds explicit binary path when provided`() {
        let script = HookInstaller.hookScript(binaryPath: "/usr/local/bin/project-hooks")
        #expect(script.contains("/usr/local/bin/project-hooks"))
    }

    @Test
    func `hook script shell quotes explicit binary path`() {
        let script = HookInstaller.hookScript(binaryPath: "/tmp/project hooks/evil\"$(touch nope)'/project-hooks")

        #expect(script.contains("'/tmp/project hooks/evil\"$(touch nope)'\\''/project-hooks'"))
    }

    @Test
    func `hook script does not evaluate command substitutions in binary path`() throws {
        let tmpDir = try makeTempDir(prefix: "install-escaping")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initResult = try runProcess("git", args: ["init", tmpDir.path])
        #expect(initResult == 0, "git init should succeed")

        let binaryDir = tmpDir.appendingPathComponent("bin/$(touch pwned)")
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true)

        let binaryPath = binaryDir.appendingPathComponent("project-hooks")
        try "#!/usr/bin/env bash\nexit 0\n".write(to: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)

        let hooksDir = tmpDir.appendingPathComponent(".git/hooks").path
        _ = try HookInstaller.installHooks(to: hooksDir, binaryPath: binaryPath.path)

        let hookPath = tmpDir.appendingPathComponent(".git/hooks/pre-commit").path
        let exitCode = try runProcess(hookPath, args: [], currentDirectory: tmpDir)
        #expect(exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("pwned").path))
    }

    @Test
    func `hook script execs binary with hook name`() {
        let script = HookInstaller.hookScript()
        #expect(script.contains("exec \"$BIN\" \"$HOOK_NAME\" \"$@\""))
    }

    @Test
    func `install hooks creates files in directory`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksDir = tmpDir.appendingPathComponent("hooks").path
        let installed = try HookInstaller.installHooks(to: hooksDir)

        #expect(installed.count == HookInstaller.hookNames.count)

        let fm = FileManager.default
        for hookName in HookInstaller.hookNames {
            let hookPath = URL(fileURLWithPath: hooksDir).appendingPathComponent(hookName).path
            #expect(fm.fileExists(atPath: hookPath), "\(hookName) hook should exist")

            let attrs = try fm.attributesOfItem(atPath: hookPath)
            let perms = attrs[FileAttributeKey.posixPermissions] as? Int
            #expect(perms == 0o755, "\(hookName) should have 755 permissions")

            let content = try String(contentsOfFile: hookPath, encoding: .utf8)
            #expect(content.hasPrefix("#!/usr/bin/env bash"))
        }
    }

    @Test
    func `install hooks creates directory if needed`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksDir = tmpDir.appendingPathComponent("nested/deep/hooks").path
        #expect(!FileManager.default.fileExists(atPath: hooksDir))

        _ = try HookInstaller.installHooks(to: hooksDir)
        #expect(FileManager.default.fileExists(atPath: hooksDir))
    }

    @Test
    func `install hooks with explicit binary path embeds it`() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksDir = tmpDir.appendingPathComponent("hooks").path
        _ = try HookInstaller.installHooks(to: hooksDir, binaryPath: "/opt/bin/project-hooks")

        let hookPath = URL(fileURLWithPath: hooksDir).appendingPathComponent("pre-commit").path
        let content = try String(contentsOfFile: hookPath, encoding: .utf8)
        #expect(content.contains("/opt/bin/project-hooks"))
    }

    // MARK: - Integration: install into a real git repo

    @Test
    func `install hooks into a git repo creates executable hooks`() throws {
        let tmpDir = try makeTempDir(prefix: "install-integration")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a git repo
        let initResult = try runProcess("git", args: ["init", tmpDir.path])
        #expect(initResult == 0, "git init should succeed")

        let hooksDir = tmpDir.appendingPathComponent(".git/hooks").path
        #expect(FileManager.default.fileExists(atPath: hooksDir))

        // Install hooks
        let installed = try HookInstaller.installHooks(
            to: hooksDir,
            binaryPath: "/usr/local/bin/project-hooks",
        )

        #expect(installed.count == 2)

        // Verify each hook is executable and has correct content
        for hookName in HookInstaller.hookNames {
            let hookPath = tmpDir.appendingPathComponent(".git/hooks/\(hookName)").path
            #expect(FileManager.default.isExecutableFile(atPath: hookPath))

            let content = try String(contentsOfFile: hookPath, encoding: .utf8)
            #expect(content.contains("#!/usr/bin/env bash"))
            #expect(content.contains("HOOK_NAME"))
            #expect(content.contains("project-hooks"))
        }
    }

    @Test
    func `install hooks into templates directory for global setup`() throws {
        let tmpDir = try makeTempDir(prefix: "install-global")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templatesHooksDir = tmpDir.appendingPathComponent("templates/hooks").path

        // Directory should not exist yet
        #expect(!FileManager.default.fileExists(atPath: templatesHooksDir))

        let installed = try HookInstaller.installHooks(to: templatesHooksDir)

        #expect(installed.count == 2)
        #expect(FileManager.default.fileExists(atPath: templatesHooksDir))

        // Hooks should be executable
        for hookName in HookInstaller.hookNames {
            let hookPath = URL(fileURLWithPath: templatesHooksDir)
                .appendingPathComponent(hookName).path
            #expect(FileManager.default.isExecutableFile(atPath: hookPath))
        }
    }

    @Test
    func `install hooks overwrites existing hooks`() throws {
        let tmpDir = try makeTempDir(prefix: "install-overwrite")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksDir = tmpDir.appendingPathComponent("hooks").path
        try FileManager.default.createDirectory(
            atPath: hooksDir,
            withIntermediateDirectories: true,
        )

        // Write an existing hook
        let existingHookPath = URL(fileURLWithPath: hooksDir)
            .appendingPathComponent("pre-commit").path
        try "#!/bin/sh\necho old hook".write(
            toFile: existingHookPath,
            atomically: true,
            encoding: .utf8,
        )

        // Install should overwrite
        _ = try HookInstaller.installHooks(to: hooksDir, binaryPath: "/new/path/project-hooks")

        let content = try String(contentsOfFile: existingHookPath, encoding: .utf8)
        #expect(!content.contains("old hook"))
        #expect(content.contains("/new/path/project-hooks"))
    }
}

// MARK: - Test helpers

private func runProcess(_ executable: String, args: [String], currentDirectory: URL? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + args
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
