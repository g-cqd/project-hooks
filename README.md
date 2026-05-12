# project-hooks

A git hooks engine for Swift and Android projects. Auto-detects platform, discovers linters, runs tests, and validates commits — all configurable via a single YAML file.

## Features

- **Platform auto-detection** — identifies iOS, Android, or mixed projects from repo markers
- **Linter discovery** — finds SwiftLint, SwiftFormat, swift-format, ktlint, detekt on your system
- **Smart test targeting** — detects changed modules and runs only the relevant tests
- **Custom tasks** — run arbitrary commands with file filtering, dependency ordering, and auto-restaging
- **Commit message validation** — enforce patterns and reject unwanted trailers on push
- **Zero-config mode** — works out of the box with sensible defaults; configuration is optional

## Installation

### Build from source

```bash
git clone https://github.com/g-cqd/project-hooks.git
cd project-hooks
swift build -c release
```

The binary is at `.build/release/project-hooks`. Copy it somewhere on your `PATH`:

```bash
cp .build/release/project-hooks ~/.local/bin/
```

### Install hooks into a repository

```bash
# Install into the current repo
project-hooks install

# Install into a specific repo
project-hooks install --path /path/to/repo

# Install globally (applies to all new git clones)
project-hooks install --global
```

`install --path` uses Git's own hook-path resolution, so regular repositories, worktrees, and submodules all install to the correct hooks directory.

## Usage

The tool runs automatically via git hooks. You can also invoke it directly:

```bash
# Run pre-commit checks
project-hooks pre-commit

# Run pre-push checks (requires remote name and URL)
project-hooks pre-push origin https://github.com/user/repo.git

# Show version
project-hooks --version
```

## Configuration

**Configuration is entirely optional** — without it, the tool auto-detects your platform and runs discovered linters.

The tool searches for config in this order (first match wins, no merging):

1. `.project-hooks.yml` in the repository root
2. `~/.config/project-hooks/config.yml`
3. `~/.project-hooks.yml`

A local config completely replaces any user-level config (replace semantics, not merge).

User-level configs support two formats (auto-detected):
- **Flat** — applies to all repos without a local config
- **Projects-list** — keyed by path/glob pattern under a `projects:` key

See [docs/configuration.md](docs/configuration.md) for full details on user-level config and pattern matching.

Custom tasks run as trusted local automation via `/bin/bash -c`. They are not sandboxed, so only use task definitions from repositories or user-level configs you trust.

### Project config example

```yaml
pre-commit:
  tasks:
    - name: "Format strings"
      run: "swift scripts/format-strings.swift"
      on-files:
        - "*.strings"
      restage: true
      timeout: 60

    - name: "Generate licenses"
      run: "scripts/update-licenses.sh"
      restage:
        - "LICENSES.txt"
      after: "Format strings"

pre-push:
  commit-message:
    pattern: "^(feat|fix|docs|chore|refactor|test|ci)(\\(.+\\))?:\\s.+"
    error: "Commit message must follow Conventional Commits format"

  reject-trailers:
    - "Co-authored-by"

  test-override:
    type: xcodebuild
    project: "App.xcodeproj"
    scheme: "AppTests"
    test-plan: "config/tests.xctestplan"
    destination: "platform=iOS Simulator,name=iPhone 16"
    broad-impact-paths:
      - "App.xcodeproj/"
      - "Package.swift"
      - "Shared/"

  tasks:
    - name: "Check changelog"
      run: "scripts/check-changelog.sh"
      timeout: 30
```

### Config file schema

The complete schema for `.project-hooks.yml`:

```
.project-hooks.yml
├── pre-commit
│   ├── pr-size                          # Optional early-warning cognitive-load check
│   │   └── …                                  same schema as pre-push.pr-size below
│   │                                          baseline reused from pre-push.work-scope.base
│   │
│   └── tasks[]                          # Custom tasks to run on commit
│       ├── name: string        (required)  Task identifier
│       ├── run: string         (required)  Shell command to execute
│       ├── on-files: [string]  (optional)  Glob patterns to filter staged files
│       ├── restage             (optional)  Re-stage files after task runs
│       │   ├── true                          → re-stages files matched by on-files
│       │   └── [string]                      → re-stages these specific paths
│       ├── after: string       (optional)  Name of task this depends on
│       └── timeout: int        (optional)  Timeout in seconds (default: 120)
│
└── pre-push
    ├── commit-message                   # Commit message validation
    │   ├── pattern: string     (required)  Regex pattern to match against
    │   └── error: string       (required)  Error message shown on failure
    │
    ├── branch-name                      # Branch name validation
    │   ├── pattern: string     (required)
    │   ├── error: string       (required)
    │   └── skip: [string]      (optional)
    │
    ├── work-scope                       # Restrict downstream checks to current work
    │   ├── base: string        (required)  Baseline branch ref, e.g. origin/develop
    │   ├── walk: enum          (optional)  default | first-parent
    │   └── commit-filter       (optional)
    │
    ├── reject-trailers: [string]        # Git trailers to reject (e.g. "Co-authored-by")
    │
    ├── pr-size                          # Cognitive-load check on the pushed diff
    │   ├── mode: enum             (optional)  warn | fail (default: warn)
    │   ├── max-additions: int     (optional)  default 800; 0/null disables
    │   ├── max-deletions: int     (optional)  default 800
    │   ├── max-files: int         (optional)  default 30
    │   ├── max-cognitive-score: float (optional)  default 18.0
    │   ├── max-scatter: float     (optional)  null/0 disables
    │   ├── volume-weight: float   (optional)  default 1.0
    │   ├── scatter-weight: float  (optional)  default 1.0
    │   ├── test-compensation: float (optional)  default 0.25
    │   ├── exclude: [string]      (optional)  globs to skip entirely
    │   └── test-patterns: [string] (optional)  globs identifying test files
    │
    ├── test-override                    # Override auto-detected test runner
    │   ├── type: enum          (required)  xcodebuild | swift | gradle
    │   ├── project: string     (optional)  Xcode project path
    │   ├── scheme: string      (optional)  Xcode scheme name
    │   ├── test-plan: string   (optional)  Path to .xctestplan file
    │   ├── destination: string (optional)  Xcode destination string
    │   ├── broad-impact-paths: [string]    Paths that trigger full test suite
    │   ├── task: string        (optional)  Gradle task override
    │   └── extra-args: [string]            Extra runner arguments
    │
    └── tasks[]                          # Custom tasks (same schema as pre-commit)
        ├── name: string        (required)
        ├── run: string         (required)
        ├── on-files: [string]  (optional)
        ├── restage             (optional)
        ├── after: string       (optional)
        └── timeout: int        (optional)
```

### Schema details

#### `pre-commit.tasks[]` and `pre-push.tasks[]`

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | `string` | yes | — | Unique task identifier. Used for logging and `after` references. |
| `run` | `string` | yes | — | Shell command executed via `/bin/bash -c`. Receives no arguments. |
| `on-files` | `[string]` | no | all files | Simple glob-like patterns (e.g. `"*.swift"`, `"Sources/**/*.swift"`). `*` can match across path separators. |
| `restage` | `bool \| [string]` | no | no restage | When `true`, re-stages files that matched `on-files`. When a list of paths, re-stages those specific files. Only meaningful for pre-commit. |
| `after` | `string` | no | — | Name of another task that must complete before this one runs. Creates a dependency edge for topological ordering. Circular dependencies are detected and reported as errors. |
| `timeout` | `int` | no | `120` | Maximum seconds the command may run before being terminated. |

#### `pre-push.commit-message`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `pattern` | `string` | yes | Regular expression validated against each pushed commit's first line. Invalid regex patterns cause an immediate failure. |
| `error` | `string` | yes | Message displayed when a commit fails validation. |

#### `pre-push.reject-trailers`

A list of git trailer keys (e.g. `"Co-authored-by"`, `"Signed-off-by"`). Any pushed commit containing a listed trailer is rejected.

#### `pre-push.test-override`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `enum` | yes | Test runner: `xcodebuild`, `swift`, or `gradle`. |
| `project` | `string` | no | Path to `.xcodeproj` (xcodebuild only). |
| `scheme` | `string` | no | Xcode scheme name (xcodebuild only). |
| `test-plan` | `string` | no | Path to `.xctestplan` file. When provided, bundles are parsed and only bundles touching changed files are selected. |
| `destination` | `string` | no | Xcode destination (e.g. `"platform=iOS Simulator,name=iPhone 16"`). |
| `broad-impact-paths` | `[string]` | no | File path prefixes. If any changed file starts with one of these, the full test suite runs regardless of module detection. |

#### `pre-push.pr-size`

A cognitive-load score derived from `git diff --numstat`. Designed to flag PRs that
are too large to review effectively, with the formula and defaults grounded in
empirical software-engineering research (Cohen 2006; Hassan 2009; Sadowski et al. 2018).
See [docs/configuration.md](docs/configuration.md#pre-pushpr-size) for the formula,
the field reference, and the full bibliography.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | `warn \| fail` | `warn` | `fail` blocks the push when any threshold is exceeded. |
| `max-additions` / `max-deletions` / `max-files` | int | 800 / 800 / 30 | Hard caps on the raw counts. Set to `0` or `null` to disable. |
| `max-cognitive-score` | float | `18.0` | Hard cap on the composite cognitive-load score. |
| `volume-weight` / `scatter-weight` | float | `1.0` | Multipliers on the two score terms. |
| `test-compensation` | float | `0.25` | Cap on score reduction from test files (`0` disables, `1` lets test-only PRs collapse to zero). |
| `exclude` | `[string]` | `[]` | Glob patterns to skip entirely (generated code, lockfiles). |
| `test-patterns` | `[string]` | built-in set | Glob patterns identifying test files for compensation. Omit to use defaults. |

The same check is also available at commit time under `pre-commit.pr-size` (same schema, independent thresholds). The commit-time variant scores `merge-base(HEAD, base)..index` so it catches an oversized PR as it grows, not only at push. Baseline is reused from `pre-push.work-scope.base`.

## How it works

### Pre-commit flow

1. **Detect platform** from repository root markers (`.xcodeproj`, `Package.swift`, `build.gradle`, etc.)
2. **Collect staged files** via `git diff --cached --name-only`
3. **Run custom tasks** in dependency order, filtering by `on-files` patterns
4. **Discover linters** available on the system
5. **Run linters** grouped by closest config file (e.g. closest `.swiftlint.yml`)

### Pre-push flow

1. **Parse push updates** from git's stdin protocol
2. **Validate commit messages** against configured pattern and rejected trailers
3. **Collect changed files** between local and remote refs
4. **Run custom tasks** (same as pre-commit)
5. **Run linters** (same as pre-commit)
6. **Run tests** — either via `test-override` config or auto-detected per-module

### Platform detection

| Marker files | Detected platform |
|---|---|
| `Package.swift`, `*.xcodeproj`, `*.xcworkspace` | iOS |
| `build.gradle`, `build.gradle.kts`, `settings.gradle`, `settings.gradle.kts` | Android |
| Both present | Mixed |
| None | Unknown |

### Supported linters

| Platform | Linter | Binary | Config files |
|---|---|---|---|
| iOS | SwiftLint | `swiftlint` | `.swiftlint.yml`, `.swiftlint.yaml` |
| iOS | SwiftFormat | `swiftformat` | `.swiftformat` |
| iOS | swift-format | `swift-format` | `.swift-format` |
| Android | ktlint | `ktlint` | `.editorconfig`, `.ktlint` |
| Android | detekt | `detekt` | `detekt.yml`, `detekt.yaml`, `config/detekt/detekt.yml` |

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GITHOOKS_TEST_TIMEOUT_SECONDS` | `1200` | Timeout for test execution |
| `GITHOOKS_BUILD_TIMEOUT_SECONDS` | `600` | Timeout for build steps |
| `GITHOOKS_DESTINATION` | `platform=iOS Simulator,name=iPhone 16` | Default Xcode simulator destination |
| `GITHOOKS_<LINTER>_TIMEOUT_SECONDS` | `120` | Per-linter timeout (e.g. `GITHOOKS_SWIFTLINT_TIMEOUT_SECONDS`) |

## Architecture

```
ProjectHooks
├── GitHooksCore (library)          # Platform-agnostic logic, reusable
│   ├── HooksConfig                 # YAML config parsing + multi-level resolution
│   ├── ProjectDetector             # Platform detection
│   ├── LinterDiscovery             # Linter discovery and resolution
│   ├── HookLogic                   # Git push parsing, test bundle selection
│   ├── ConfigResolver              # Config file tree walking
│   ├── CommitMessageValidator      # Commit message validation
│   ├── CustomTaskRunner            # Glob matching, task dependency ordering
│   ├── TestTargetResolver          # Module detection, test command building
│   └── TestOutputParser            # Test output diagnostics
│
└── GitHooksCLI (executable)        # CLI interface
    ├── GitHooksCLI                  # Entry point, subcommand routing
    ├── PreCommitCommand             # pre-commit hook implementation
    ├── PrePushCommand               # pre-push hook implementation
    ├── HookRunner                   # Process execution, git helpers
    ├── LinterRunner                 # Linter invocation
    └── TestDiagnostics              # Test failure reporting
```

## Requirements

- macOS 26+
- Swift 6.2+

## License

[MIT](LICENSE)
