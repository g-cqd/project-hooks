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
3. Runs custom tasks defined in `.project-hooks.yml` (if present), in trusted repositories only
4. Discovers linters available on the system and runs them on the staged content: a private copy of the index, with the lint configuration files (and the files that SwiftLint configurations include) as staged
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
5. Collects the files that each distinct pushed commit changes — restricted by `work-scope` if configured
6. Runs linters on each pushed commit's changed files, from a private copy of that commit, so neither the checked-out branch nor uncommitted changes affect the verdict
7. In trusted repositories, checks each pushed commit out in a temporary worktree, with its submodules, and runs the custom tasks and the tests there (auto-detected or via `test-override` config), as that commit's own `.project-hooks.yml` defines them; the worktree is removed afterwards. Commands there run without the `GIT_DIR`-style variables that git sets for the hook, and without your uncommitted or untracked files
8. Exits non-zero if any check fails, blocking the push

> **Note on `work-scope`:** when set, the changed-file set used for steps 5–7 is computed from `merge-base(HEAD, <base>)..HEAD`, with optional `--first-parent` walking and an optional commit-pattern filter. Commit-message validation in step 3 is **not** scoped — every pushed commit is validated regardless. See [configuration.md](configuration.md#pre-pushwork-scope) for details.

### `project-hooks check-localization [paths...]`

Static-analyses Swift sources for SwiftUI string literals missing the
`comment:` argument that translators rely on. Designed to be run on
the pre-commit hook against staged files, but also usable standalone.

```bash
project-hooks check-localization Sources/ App/Views/
project-hooks check-localization --format json Sources/
project-hooks check-localization --allow-comment dev-only Sources/
project-hooks check-localization --include-previews Sources/
```

**Flagged call sites:** `Text(...)`, `Button(...)`, `Label(...)`,
`Toggle(...)`, `Picker(...)`, `Section(...)`, `TextField(...)`,
`.navigationTitle(...)`, `Stepper(...)`, `DatePicker(...)`.

**Skipped automatically:**

- Lines containing `String(localized:`, `LocalizedStringKey(`,
  `LocalizedStringResource(`, `verbatim:`, or `comment:`.
- Debug-only APIs: `Logger`, `print`, `assertionFailure`,
  `preconditionFailure`, `fatalError`.
- Strings used as identifiers (e.g. `Image(systemName:)`,
  `URL(string:)`, `Notification.Name(...)`).
- Files inside `#Preview { … }` macros.
- Files whose name ends in `Preview.swift` / `Previews.swift` /
  `+Preview.swift` (override with `--include-previews`).
- Lines marked with the escape-hatch comment (`// not-localized`
  by default; configurable via `--allow-comment`).

**Output formats:**

- `text` (default): Xcode-style `path:line:col: warning: …` written to
  stderr, summary line at the end.
- `json`: array of `{file, line, column, snippet, api, kind}` objects
  to stdout.

**Exit codes:** `0` if no issues, `1` if one or more issues are found.

### `project-hooks repair [<directory>...]`

Rewrites the `pre-commit` and `pre-push` hooks that project-hooks generated, so that they run this binary. Git copies hooks into each repository at clone time, so repositories created before an update keep their old hooks until you repair them.

| Option | Description |
|---|---|
| `<directory>...` | Directories to search for repositories. Without one, the current repository. |
| `--max-depth <n>` | How many directory levels below each directory to search (default: 4). |
| `--dry-run` | Report what would change without writing anything. |

It finds repositories, their linked worktrees, and their submodules by reading `.git` entries, without running git in them, and skips build directories such as `.build` and `DerivedData`. Hooks from other tools stay unchanged, and running the command again changes nothing.

### `project-hooks trust [--revoke] [--path <repo>]`

Lets project-hooks run the repository's own code: its custom tasks, its builds and tests on push, and linters that it builds itself. Until then, its hooks run only installed linters and commit checks, and say what they skipped. `trust` records the decision as `project-hooks.trusted` in the repository's local git configuration; `--revoke` removes it. See [Trust a repository](../README.md#trust-a-repository).

### `project-hooks --version`

Prints the current version.

## How installed hooks find the binary

`project-hooks install` writes `pre-commit` and `pre-push` scripts that locate the `project-hooks` binary and delegate to it. Generated hooks search in this order:

1. The binary path embedded at install time
2. `~/.local/bin/project-hooks`

The hooks never look inside the repository or on `PATH`. Git does not run hooks that a repository ships, and a cloned repository must not be able to choose the binary that these hooks run either. If neither path holds an executable, the hook fails. For the same reason the script runs under `/bin/bash` rather than `env bash`, and project-hooks drops relative `PATH` entries, such as `.` or `node_modules/.bin`, from the environment of every command it runs in the repository.

The install command resolves hook directories through Git, so normal repositories, worktrees, and submodules use the correct hooks path.

## Zero-config mode

Without a `.project-hooks.yml` file (in the repo or user directories), project-hooks still:

- Detects your platform from repo markers
- Discovers linters installed on your system
- Runs discovered linters on staged/changed files
- Auto-detects test modules and runs tests on push, in repositories that you trust

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

Linters are discovered by checking if their binary exists via `which` or in known fallback paths, except swift-format:

| Platform | Linter | Binary | Fallback path |
|---|---|---|---|
| iOS | SwiftLint | `swiftlint` | `BuildTools/.build/release/swiftlint` |
| iOS | SwiftFormat | `swiftformat` | `BuildTools/.build/release/swiftformat` |
| iOS | swift-format | `swift-format` | — |
| Android | ktlint | `ktlint` | — |
| Android | detekt | `detekt` | — |

Fallback paths are inside the repository, so they are searched only in trusted repositories.

swift-format is never looked up on `PATH`, because a git client launched from the Dock gets a different `PATH` from your terminal, and a different swift-format can reach a different verdict on the same files:

1. When the repository root has a `.swift-version`, project-hooks asks swiftly (from `~/.swiftly/bin`, `/opt/homebrew/bin` or `/usr/local/bin`, in that order) for that toolchain, and uses its `swift-format`.
2. Otherwise, or when swiftly or that toolchain is missing, it uses the `swift-format` of the toolchain that `xcode-select` or `DEVELOPER_DIR` selects (`/usr/bin/xcrun --find swift-format`).

The hook prints the binary it runs, its version, and why it fell back when it did.

Files are grouped by their closest config file (walking up the directory tree). This means monorepos with multiple linter configs are handled correctly. Every linter requires a config: it lints the files that a config covers, wherever that config is (for example only in `Packages/Kit/`), and skips the others with a note.

Every group runs, even after one fails, and the hook then blocks once with the list of groups that did not pass.

project-hooks remembers which files each linter passed, in `~/Library/Caches/project-hooks/lint`, keyed by the linter's binary, every lint configuration file in the repository, and the file's path and content. Pre-push therefore skips the files that the commit hook already linted, and a commit retried after a lint failure lints only the groups that failed. Changing any of those inputs lints the file again. SwiftLint results are not cached when a configuration includes an external file or URL, or the snapshot cannot cover every include.

## Test targeting

### Auto-detection (no config)

The tool finds module boundaries by walking up from each changed file looking for:

- `Package.swift` → Swift package module
- `*.xcodeproj` → Xcode project module
- `build.gradle` / `build.gradle.kts` → Gradle module

It then runs tests only for the affected modules. Each Swift package or Xcode project of each repository has its own build directory in `~/Library/Caches/project-hooks/builds` (`GITHOOKS_CACHE_DIR`), apart from the repository's `.build` and Xcode's DerivedData; Gradle builds in the worktree and reuses outputs through its build cache. Pushes reuse it, so they rebuild only what changed, and the verification worktree has the same path on every push of a repository. When the build directories together exceed `GITHOOKS_BUILD_CACHE_LIMIT_GB` (10 GB by default), the least recently used ones are removed, except those that a run is using. Everything under the cache directory can be deleted at any time.

project-hooks also remembers which test commands passed on which tree, in `~/Library/Caches/project-hooks/results`. Pushing a tree that already passed, for example to a second remote or after rewording a commit message, skips them. A result applies only to the same tree, module and command, with the same `swift --version` or `xcodebuild -version` and the same `DEVELOPER_DIR`, `TOOLCHAINS`, `SDKROOT` and `JAVA_HOME`. A test that depends on something else, such as the network or the date, can pass once and fail later; set `GITHOOKS_NO_CACHE=1` to run everything.

Earlier versions built in a new directory under `$TMPDIR/project-hooks-build` for every run: 1.0 never removed them, and 1.1 removed them only when the run finished, not when it was interrupted. project-hooks no longer uses that directory, and you can delete it.

### Test override (configured)

When `test-override` is set in config, the tool uses the specified runner. For `xcodebuild` with a test plan, it parses the `.xctestplan` file to extract test bundles and selects only bundles whose source directories contain changed files.

If any changed file matches a `broad-impact-paths` prefix, all bundles run.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GITHOOKS_TEST_TIMEOUT_SECONDS` | `1200` | Max seconds for test execution |
| `GITHOOKS_DESTINATION` | `generic/platform=iOS Simulator` | Xcode simulator destination. Defaults to the generic form so xcodebuild picks any available simulator. |
| `GITHOOKS_<LINTER>_TIMEOUT_SECONDS` | `120` | Per-linter timeout. Replace `<LINTER>` with the uppercase linter name (e.g. `GITHOOKS_SWIFTLINT_TIMEOUT_SECONDS`) |
| `GITHOOKS_CACHE_DIR` | `~/Library/Caches/project-hooks` | Where build directories, verification worktrees and locks live between runs |
| `GITHOOKS_BUILD_CACHE_LIMIT_GB` | `10` | Total size of the build directories kept between pushes |
| `GITHOOKS_NO_CACHE` | unset | Set to `1` to run linters and tests even on content that passed before |

## Timeouts and process management

Commands are executed with configurable timeouts. When a timeout expires:

1. The process tree receives `SIGTERM` (graceful termination)
2. If still running after a grace period, the process tree receives `SIGKILL`
3. The task is reported as failed with timeout diagnostics

When the hook itself receives `SIGINT` (Ctrl-C), `SIGTERM` or `SIGHUP`, it stops the running command's process tree the same way, removes its lint snapshot and verification worktree, and exits with status 128 plus the signal number.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed |
| `1` | One or more checks failed |

Any non-zero exit from a custom task, linter, or test runner causes the hook to fail and block the git operation.

Each linter's own violations code (2 for SwiftLint and detekt, 1 for swift-format, SwiftFormat and ktlint) is reported as violations; any other non-zero exit is reported as a failure to run, with the linter's output. SwiftLint runs with `--force-exclude`, so it skips files that its configuration excludes, and a group whose files are all excluded passes.
