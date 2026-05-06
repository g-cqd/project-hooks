# Usage Guide

## Quick start

1. Build and install the binary:

```bash
swift build -c release
cp .build/release/project-hooks ~/.local/bin/
```

2. Install hooks into the current repository:

```bash
project-hooks install
```

3. Or install into a specific repository:

```bash
project-hooks install --path /path/to/your/repo
```

4. To apply hooks to newly initialized or cloned repositories, install globally:

```bash
project-hooks install --global
```

5. Optionally create a config file (see [configuration.md](configuration.md)):
   - Per-project: `.project-hooks.yml` in the repo root
   - Per-user: `~/.config/project-hooks/config.yml` or `~/.project-hooks.yml`

## CLI commands

### `project-hooks pre-commit`

Runs pre-commit checks on staged files. Automatically invoked by git when committing.

**What it does:**

1. Detects the project platform (iOS, Android, mixed)
2. Collects staged files from the git index
3. Runs custom tasks defined in `.project-hooks.yml` (if present)
4. Discovers and runs linters available on the system
5. Exits non-zero if any check fails, blocking the commit

### `project-hooks pre-push <remote-name> <remote-url>`

Runs pre-push checks on commits about to be pushed. Automatically invoked by git when pushing.

**Arguments:**

| Argument | Description |
|---|---|
| `remote-name` | Name of the remote (e.g. `origin`) |
| `remote-url` | URL of the remote |

**What it does:**

1. Reads push update lines from stdin (git hook protocol)
2. Validates branch name(s) against the configured pattern (if `branch-name` is set)
3. Validates commit messages against configured patterns
4. Checks for rejected git trailers
5. Collects files changed across all pushed commits — restricted by `work-scope` if configured
6. Runs custom tasks
7. Runs linters
8. Runs tests (auto-detected or via `test-override` config)
9. Exits non-zero if any check fails, blocking the push

> **Note on `work-scope`:** when set, the changed-file set used for steps 5–8 is computed from `merge-base(HEAD, <base>)..HEAD`, with optional `--first-parent` walking and an optional commit-pattern filter. Commit-message validation in step 3 is **not** scoped — every pushed commit is validated regardless. See [configuration.md](configuration.md#pre-pushwork-scope) for details.

### `project-hooks --version`

Prints the current version.

## How installed hooks find the binary

`project-hooks install` writes `pre-commit` and `pre-push` scripts that locate the `project-hooks` binary and delegate to it. Generated hooks search in this order:

1. `<repoRoot>/.build/release/project-hooks`
2. The binary path embedded at install time
3. `~/.local/bin/project-hooks`
4. System `PATH`

The install command resolves hook directories through Git, so normal repositories, worktrees, and submodules use the correct hooks path.

## Zero-config mode

Without a `.project-hooks.yml` file (in the repo or user directories), project-hooks still:

- Detects your platform from repo markers
- Discovers linters installed on your system
- Runs discovered linters on staged/changed files
- Auto-detects test modules and runs tests on push

Configuration only adds custom tasks, commit message rules, and test runner overrides on top of this baseline.

## Config resolution

The tool searches for configuration in this order (first match wins, no merging):

| Priority | Location | Description |
|----------|----------|-------------|
| 1 | `<repoRoot>/.project-hooks.yml` | Project-specific (committed to repo) |
| 2 | `~/.config/project-hooks/config.yml` | XDG user config |
| 3 | `~/.project-hooks.yml` | Home directory config |

When a config is found at any level, it replaces all lower-priority configs entirely (no merging).

User-level configs can be either a flat config (applies to all repos) or a projects-list config (keyed by path/glob patterns). The format is auto-detected by the presence of a top-level `projects` key.

Example projects-list config (`~/.config/project-hooks/config.yml`):

```yaml
projects:
  ~/Developer/work/*:
    pre-push:
      commit-message:
        pattern: "^JIRA-\\d+\\s"
        error: "Need JIRA ticket"

  ~/Developer/personal/*:
    pre-commit:
      tasks:
        - name: "Format"
          run: "swift-format format --in-place ."
```

See [configuration.md](configuration.md) for full reference.

## Platform detection

The tool detects your project platform by looking for marker files in the repository root:

| Platform | Marker files |
|---|---|
| iOS | `Package.swift`, `*.xcodeproj`, `*.xcworkspace` |
| Android | `build.gradle`, `build.gradle.kts`, `settings.gradle`, `settings.gradle.kts` |
| Mixed | Both iOS and Android markers present |
| Unknown | No markers found |

When filtering files, it uses extensions: `.swift` for iOS, `.kt`/`.kts`/`.java` for Android.

## Linter discovery

Linters are discovered by checking if their binary exists via `which` or in known fallback paths:

| Platform | Linter | Binary | Fallback path |
|---|---|---|---|
| iOS | SwiftLint | `swiftlint` | `BuildTools/.build/release/swiftlint` |
| iOS | SwiftFormat | `swiftformat` | `BuildTools/.build/release/swiftformat` |
| iOS | swift-format | `swift-format` | — |
| Android | ktlint | `ktlint` | — |
| Android | detekt | `detekt` | — |

Files are grouped by their closest config file (walking up the directory tree). This means monorepos with multiple linter configs are handled correctly.

## Test targeting

### Auto-detection (no config)

The tool finds module boundaries by walking up from each changed file looking for:

- `Package.swift` → Swift package module
- `*.xcodeproj` → Xcode project module
- `build.gradle` / `build.gradle.kts` → Gradle module

It then runs tests only for the affected modules, using isolated build directories to avoid conflicts.

### Test override (configured)

When `test-override` is set in config, the tool uses the specified runner. For `xcodebuild` with a test plan, it parses the `.xctestplan` file to extract test bundles and selects only bundles whose source directories contain changed files.

If any changed file matches a `broad-impact-paths` prefix, all bundles run.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GITHOOKS_TEST_TIMEOUT_SECONDS` | `1200` | Max seconds for test execution |
| `GITHOOKS_BUILD_TIMEOUT_SECONDS` | `600` | Max seconds for build steps |
| `GITHOOKS_DESTINATION` | `platform=iOS Simulator,name=iPhone 16` | Xcode simulator destination |
| `GITHOOKS_<LINTER>_TIMEOUT_SECONDS` | `120` | Per-linter timeout. Replace `<LINTER>` with the uppercase linter name (e.g. `GITHOOKS_SWIFTLINT_TIMEOUT_SECONDS`) |

## Timeouts and process management

Commands are executed with configurable timeouts. When a timeout expires:

1. The process tree receives `SIGTERM` (graceful termination)
2. If still running after a grace period, the process tree receives `SIGKILL`
3. The task is reported as failed with timeout diagnostics

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed |
| `1` | One or more checks failed |

Any non-zero exit from a custom task, linter, or test runner causes the hook to fail and block the git operation.
