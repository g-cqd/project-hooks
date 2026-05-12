# Configuration Reference

project-hooks is configured via a `.project-hooks.yml` file. The config file is **optional** — without it, the tool runs with auto-detection only.

## Config file locations

The tool searches for configuration in these locations (first match wins, no merging):

| Priority | Location | Description |
|----------|----------|-------------|
| 1 (highest) | `<repoRoot>/.project-hooks.yml` | Project-specific config |
| 2 | `~/.config/project-hooks/config.yml` | XDG user config |
| 3 (lowest) | `~/.project-hooks.yml` | Home directory config |

When a config is found, it is used as-is — configs are **never merged** across levels. A local config completely replaces any user-level config.

## User-level config formats

User-level configs (`~/.config/project-hooks/config.yml` or `~/.project-hooks.yml`) support two formats, detected automatically:

### Flat format

A flat config applies to **all repositories** that don't have their own local config:

```yaml
pre-commit:
  tasks:
    - name: "Format"
      run: "swift-format format --in-place ."
      restage: true

pre-push:
  commit-message:
    pattern: "^[A-Z]+-\\d+\\s"
    error: "Commit must start with a ticket number"
```

### Projects-list format

A projects-list config uses path patterns to apply different configurations per project:

```yaml
projects:
  ~/Developer/work/*:
    pre-commit:
      tasks:
        - name: "Strict lint"
          run: "swiftlint --strict"
    pre-push:
      commit-message:
        pattern: "^JIRA-\\d+\\s"
        error: "Need JIRA ticket"

  ~/Developer/personal/*:
    pre-commit:
      tasks:
        - name: "Format"
          run: "swift-format format --in-place ."

  ~/Developer/oss/*:
    pre-push:
      reject-trailers:
        - "Signed-off-by"
```

**Format detection**: if the top-level YAML contains a `projects` key (as a dictionary), it's treated as a projects-list config. Otherwise it's a flat config.

**Pattern matching rules**:

- Patterns use `fnmatch`-style globbing (`*`, `?`, `[abc]`, `[!abc]`)
- `~` at the start is expanded to the home directory
- `*` matches across path separators (e.g. `~/dev/*` matches `~/dev/a/b/c`)
- Patterns are matched alphabetically — the first matching pattern wins
- If no pattern matches the current repo, the file is skipped (falls through to the next priority level)

## Config file schema

```
.project-hooks.yml
├── pre-commit
│   └── tasks[]                          # Custom tasks to run on commit
│       ├── name: string        (required)
│       ├── run: string         (required)
│       ├── on-files: [string]  (optional)
│       ├── restage             (optional)  true | [string]
│       ├── after: string       (optional)
│       └── timeout: int        (optional)
│
└── pre-push
    ├── commit-message
    │   ├── pattern: string     (required)
    │   ├── error: string       (required)
    │   └── base: string        (optional)  baseline ref (e.g. "origin/develop"); commits
    │                                       reachable from this ref are excluded from validation
    │
    ├── branch-name
    │   ├── pattern: string     (required)
    │   ├── error: string       (required)
    │   └── skip: [string]      (optional)  exact branch names to bypass (e.g. main, develop)
    │
    ├── work-scope
    │   ├── base: string        (required)  baseline branch ref, e.g. "origin/develop"
    │   ├── walk: enum          (optional)  default | first-parent (default: first-parent)
    │   └── commit-filter                    (optional)
    │       ├── branch-pattern: string  (required)  regex extracting an ID from the branch name
    │       ├── commit-pattern: string  (required)  regex extracting an ID from each commit's first line
    │       ├── on-mismatch: enum       (optional)  skip | warn | fail (default: warn)
    │       └── include-merges: bool    (optional)  default true; merge commits bypass the filter
    │
    ├── reject-trailers: [string]
    │
    ├── pr-size                          # Optional cognitive-load check on the pushed diff
    │   ├── mode: enum             (optional)  warn | fail (default: warn)
    │   ├── max-additions: int     (optional)  0 disables; default 800
    │   ├── max-deletions: int     (optional)  0 disables; default 800
    │   ├── max-files: int         (optional)  0 disables; default 30
    │   ├── max-scatter: float     (optional)  0/null disables; uncapped by default
    │   ├── max-cognitive-score: float (optional)  0 disables; default 18.0
    │   ├── volume-weight: float   (optional)  default 1.0
    │   ├── scatter-weight: float  (optional)  default 1.0
    │   ├── test-compensation: float (optional)  cap on test-driven score reduction (0..1); default 0.25
    │   ├── exclude: [string]      (optional)  glob patterns of files to skip entirely
    │   └── test-patterns: [string] (optional)  glob patterns identifying test files
    │
    ├── test-override
    │   ├── type: enum          (required)  xcodebuild | swift | gradle
    │   ├── project: string     (optional)  xcodebuild only
    │   ├── scheme: string      (optional)  xcodebuild only
    │   ├── test-plan: string   (optional)  xcodebuild only
    │   ├── destination: string (optional)  xcodebuild only
    │   ├── broad-impact-paths: [string]   (optional)  xcodebuild only
    │   ├── task: string        (optional)  gradle only — single gradle task to run instead of bare `test`
    │   └── extra-args: [string]           (optional)  free-form args appended to the constructed command (any runner)
    │
    └── tasks[]                          # Same schema as pre-commit tasks
```

## Complete example

```yaml
pre-commit:
  tasks:
    # Format localization files and re-stage them
    - name: "Format strings"
      run: "swift scripts/format-strings.swift"
      on-files:
        - "*.strings"
        - "*.stringsdict"
      restage: true
      timeout: 60

    # Generate license header after formatting
    - name: "License headers"
      run: "scripts/add-license-headers.sh"
      restage:
        - "Sources/**/*.swift"
      after: "Format strings"

    # Validate JSON fixtures
    - name: "Validate fixtures"
      run: "python3 scripts/validate-fixtures.py"
      on-files:
        - "Tests/Fixtures/**/*.json"

pre-push:
  # Require Conventional Commits format
  commit-message:
    pattern: "^(feat|fix|docs|chore|refactor|test|ci)(\\(.+\\))?:\\s.+"
    error: "Commit message must follow Conventional Commits (e.g. 'feat: add login')"

  # Reject AI-generated co-author trailers
  reject-trailers:
    - "Co-authored-by"
    - "Signed-off-by"

  # Use a specific Xcode test plan
  test-override:
    type: xcodebuild
    project: "App.xcodeproj"
    scheme: "AppTests"
    test-plan: "config/UnitTests.xctestplan"
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

## Section reference

### `pre-commit`

Contains tasks that run before each commit. These operate on staged files.

### `pre-commit.tasks[]`

An ordered list of custom tasks. Tasks are topologically sorted by `after` dependencies before execution.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | `string` | **yes** | — | Unique identifier for the task. Used in log output and as the target for `after` references from other tasks. |
| `run` | `string` | **yes** | — | Shell command executed via `/bin/bash -c`. The command receives no arguments. The working directory is the repository root. A non-zero exit code fails the hook. |
| `on-files` | `[string]` | no | all staged files | Simple glob-like patterns to filter which staged files trigger this task. `*` can match across path separators. The task is **skipped** if no staged files match any pattern. |
| `restage` | `bool \| [string]` | no | disabled | Controls automatic re-staging after the task runs. When `true`, files that matched `on-files` are re-staged via `git add`. When a list of paths, those specific paths are re-staged. Only applies to pre-commit tasks. |
| `after` | `string` | no | — | Name of another task that must complete before this one. Creates a dependency edge. Circular dependencies are detected and cause an error. If the dependency task was skipped (no matching files), this task is also skipped. |
| `timeout` | `int` | no | `120` | Maximum seconds the command may run. After this, `SIGTERM` is sent, followed by `SIGKILL` if the process doesn't exit. |

Custom tasks are trusted local automation. They are intentionally executed by a shell and are not sandboxed; only use project or user-level task definitions you trust.

### `pre-push`

Contains commit validation, test configuration, and tasks that run before each push.

### `pre-push.commit-message`

Validates the first line of each commit being pushed against a regex pattern.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `pattern` | `string` | **yes** | Regular expression. Each pushed commit's message (first line) is matched against this pattern. An invalid regex causes an immediate config-level failure. |
| `error` | `string` | **yes** | Human-readable error message displayed when a commit fails validation. |
| `base` | `string` | no | Optional baseline ref (e.g. `origin/develop`). Commits reachable from this ref are excluded from validation. Use this on long-lived integration branches whose history contains commits authored by tools (Weblate, release bots, merge commits) that pre-date this hook or that you don't control. When `base` doesn't resolve, a warning is printed and the full push range is validated (no failure). |

### `pre-push.branch-name`

Validates each pushed branch name against a regex. Tag and deletion updates are ignored.

```yaml
pre-push:
  branch-name:
    pattern: "^((feature|bugfix)/[a-z]+/[A-Z]+-\\d+-[a-z0-9-]+|misc/.+)$"
    error: "Branch must follow feature/<scope>/<TICKET>-slug or misc/..."
    skip:
      - "main"
      - "develop"
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `pattern` | `string` | **yes** | Regex matched against the *whole* short branch name (after stripping `refs/heads/`). |
| `error` | `string` | **yes** | Message displayed when the branch fails to match. |
| `skip` | `[string]` | no | Exact branch names that bypass validation (handy for `main`/`develop`). Matching is case-sensitive and exact (no globs). |

Validation runs once per pushed branch ref. Invalid regex causes an immediate config-level failure.

### `pre-push.work-scope`

Restricts the set of commits/files that downstream checks (lint, custom tasks, tests) operate on. The intent is to ignore commits that aren't part of *your* current work — e.g. ancestor commits picked up by branching from another feature branch, or commits brought in by an in-branch merge of your integration branch.

```yaml
pre-push:
  work-scope:
    base: "origin/develop"
    walk: first-parent
    commit-filter:
      branch-pattern: "MAIN-\\d+"
      commit-pattern: "^MAIN-\\d+"
      on-mismatch: warn
      include-merges: true
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `base` | `string` | **yes** | — | Integration branch ref (e.g. `origin/develop`, `origin/main`). The push range becomes `merge-base(HEAD, base)..HEAD`. |
| `walk` | `enum` | no | `first-parent` | `default` walks every commit in the range. `first-parent` walks only the spine of your branch, keeping merge commits but skipping commits brought in by them. Affects the commit list used by `commit-filter`; doesn't affect file collection when no filter is configured. |
| `commit-filter` | object | no | — | Optional second-stage filter that drops commits whose extracted identifier doesn't match the branch's. See below. |

**Bypass and fallback behavior:**

- When pushing the baseline branch itself (e.g. `git push origin develop` with `base: origin/develop`), work-scope is bypassed.
- When `base` doesn't resolve as a ref, a warning is printed and the legacy push range is used (no failure).
- When `merge-base(HEAD, base)` is empty (disjoint histories), same fallback applies.
- When `merge-base(HEAD, base) == HEAD` (HEAD is already in the baseline), the changed-file set is empty and downstream checks are skipped.

**Commit-message validation is unaffected by `work-scope`** — every pushed commit is still validated against `commit-message` rules, since a malformed commit shouldn't sneak through just because work-scope filters it out for lint purposes. To exclude upstream commits from commit-message validation specifically, set `commit-message.base`.

### `pre-push.work-scope.commit-filter`

Optional. Drops commits whose message identifier doesn't equal the branch's identifier. Useful when you stack feature branches (`feature/MAIN-123` branched off `feature/MAIN-100`) and want to keep MAIN-100 commits out of MAIN-123's pre-push checks.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `branch-pattern` | `string` | **yes** | — | Regex applied to the branch name. The first match is the branch's identifier. If no match, the filter is disabled with a warning (all commits are kept). |
| `commit-pattern` | `string` | **yes** | — | Regex applied to each commit's first line. The first match is the commit's identifier. |
| `on-mismatch` | enum | no | `warn` | What to do with non-matching commits: `skip` drops silently, `warn` drops with a per-commit log, `fail` aborts the push. |
| `include-merges` | bool | no | `true` | When `true`, merge commits are kept regardless of pattern match (they often have generated messages). Set `false` to also subject merges to the filter. |

### `pre-push.reject-trailers`

```yaml
reject-trailers:
  - "Co-authored-by"
  - "Signed-off-by"
```

A list of git trailer keys. If any pushed commit contains a trailer matching one of these keys, the push is rejected. Matching is case-sensitive and expects the standard `Key:` trailer prefix.

### `pre-push.pr-size`

Computes a cognitive-load score from the diff stats of the pushed range and warns
(or blocks) when the change is too large for effective review.

```yaml
pre-push:
  pr-size:
    mode: warn                # warn | fail
    max-additions: 800
    max-deletions: 800
    max-files: 30
    max-cognitive-score: 18.0
    max-scatter: null         # leave unset to score-only
    volume-weight: 1.0
    scatter-weight: 1.0
    test-compensation: 0.25
    exclude:
      - "Package.resolved"
      - "*.lock"
      - "Generated/*"
    test-patterns:            # omit to use the built-in defaults
      - "Tests/*"
      - "*Tests.swift"
      - "*Spec.kt"
```

#### Formula

`CL = (volume · w_v + scatter · w_s) · (1 − min(test_ratio, 1) · test_compensation)`

| Term | Definition |
|------|------------|
| `volume` | `ln(1 + A + D)` over non-test, non-excluded lines. Log-scaling reflects sub-linear growth of review effort with size. |
| `scatter` | Normalized Shannon entropy of changes across files (Hassan, ICSE 2009), scaled by `ln(1 + F)`. Maximum scatter is `ln(F+1)` when every file changes the same amount; zero when only one file changes. |
| `test_ratio` | `(test_added + test_deleted) / (total_added + total_deleted)`. Test compensation caps how much a test-heavy diff can reduce the score. |

Bands (informational, printed in the report):

| Band | Range | Empirical anchor |
|------|-------|------------------|
| Small | `CL < 5` | Google median ~24 LOC, 2–3 files (Sadowski et al. ICSE 2018). |
| Medium | `5 ≤ CL < 10` | OSS median ~44 LOC (Rigby & Bird FSE 2013). |
| Large | `10 ≤ CL < 18` | Approaching SmartBear 200-LOC inflection (Cohen 2006). |
| Oversized | `CL ≥ 18` | Above Cohen's 400-LOC ceiling. |

#### Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `mode` | enum | no | `warn` | `warn` prints the report and continues. `fail` blocks the push when any threshold is exceeded. |
| `max-additions` | int | no | `800` | Hard cap on non-test added lines. `0` or `null` disables this check. |
| `max-deletions` | int | no | `800` | Hard cap on non-test deleted lines. `0` or `null` disables. |
| `max-files` | int | no | `30` | Hard cap on non-test files changed. `0` or `null` disables. |
| `max-scatter` | float | no | unset | Hard cap on the scatter sub-score. `null`/`0` disables (default). |
| `max-cognitive-score` | float | no | `18.0` | Hard cap on the composite cognitive-load score. `0` or `null` disables. |
| `volume-weight` | float | no | `1.0` | Multiplier on the volume term. Lower if your reviewers handle long diffs well; raise to punish bulk. |
| `scatter-weight` | float | no | `1.0` | Multiplier on the scatter term. Raise to disincentivize "shotgun" changes across modules. |
| `test-compensation` | float | no | `0.25` | Maximum fraction by which test-heavy PRs can reduce their score. `0` disables compensation; `1` lets a fully-test PR collapse to zero. |
| `exclude` | [string] | no | `[]` | Glob patterns of files to drop before any counting. Use for generated code, lockfiles, vendored sources. |
| `test-patterns` | [string] | no | built-in set | Glob patterns identifying test files for the compensation term. Omit the key to use defaults (`Tests/*`, `*/Tests/*`, `*Tests.swift`, `*Test.kt`, etc.). An explicit empty list disables test classification entirely. |

#### Scope

The metric is computed over the same baseline used by `work-scope` (`merge-base(HEAD, base)..HEAD`)
when that block is present; otherwise it falls back to the push range. Commit-filter
results do **not** affect the metric — reviewers must read the actual tree delta
regardless of which commits authored it. Trim with `exclude` patterns instead.

#### Research grounding

- Cohen, J. (2006). *Best Kept Secrets of Peer Code Review*. SmartBear/Cisco — 200–400 LOC inflection.
- Kemerer, C. & Paulk, M. (1995). *The Impact of Design and Code Reviews on Software Quality*. IEEE TSE — review-rate vs defect detection.
- Bacchelli, A. & Bird, C. (2013). *Expectations, Outcomes, and Challenges of Modern Code Review*. ICSE — reviewer attention budget.
- Rigby, P. & Bird, C. (2013). *Convergent Contemporary Software Peer Review Practices*. FSE — OSS median size.
- Sadowski, C. et al. (2018). *Modern Code Review: A Case Study at Google*. ICSE — Google median ~24 LOC.
- Kononenko, O. et al. (2016). *Code Review Quality: How Developers See It*. ICSE — size degrades comment density.
- Hassan, A. E. (2009). *Predicting Faults Using the Complexity of Code Changes*. ICSE — entropy as a fault predictor.
- Nagappan, N. et al. (2010). *Change Bursts as Defect Predictors*. ISSRE — file-count signal independent of LOC.
- Halstead, M. H. (1977). *Elements of Software Science*. Elsevier — `V = N · log₂(n)` motivating log-scaling.

### `pre-push.test-override`

Overrides the auto-detected test runner. When not set, the tool auto-detects test modules from changed files.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `enum` | **yes** | Test runner to use. One of: `xcodebuild`, `swift`, `gradle`. |
| `project` | `string` | no | Path to the `.xcodeproj` file. Used with `xcodebuild` type. |
| `scheme` | `string` | no | Xcode scheme name. Used with `xcodebuild` type. |
| `test-plan` | `string` | no | Path to an `.xctestplan` file. When set, the tool parses the plan's JSON to extract test bundle names and maps changed files to bundles. Only matching bundles are tested. |
| `destination` | `string` | no | Xcode destination string (e.g. `"platform=iOS Simulator,name=iPhone 16"`). Overrides the default and the `GITHOOKS_DESTINATION` env var. |
| `broad-impact-paths` | `[string]` | no | Path prefixes. If any changed file starts with one of these prefixes, **all** test bundles run regardless of file-to-bundle mapping. Useful for project files, shared modules, or CI config. |

### `pre-push.tasks[]`

Same schema as `pre-commit.tasks[]`. These tasks run on the files changed across all pushed commits (not just staged files).

## Minimal config examples

### Lint-only (custom task)

```yaml
pre-commit:
  tasks:
    - name: "Sort imports"
      run: "swift-format format --in-place Sources/**/*.swift"
      restage: true
```

### Commit message enforcement only

```yaml
pre-push:
  commit-message:
    pattern: "^[A-Z]+-\\d+\\s"
    error: "Commit must start with a ticket number (e.g. PROJ-123)"
```

### Android Gradle test override

```yaml
pre-push:
  test-override:
    type: gradle
```

Bare `gradle test` aggregates every test task in the project. For multi-flavor / multi-variant projects (e.g. Android with product flavors) this can run the full matrix and take a very long time. Use `task` to scope to a single variant:

```yaml
pre-push:
  test-override:
    type: gradle
    task: ":base:testDevelopDebugUnitTest"
```

### Free-form runner args (`extra-args`)

Sometimes you need to pass a runner-specific flag we don't model directly. `extra-args` is appended to the constructed command verbatim, regardless of `type`.

```yaml
# xcodebuild: skip plugin validation, quiet output, set a build flag
pre-push:
  test-override:
    type: xcodebuild
    scheme: "AppTests"
    extra-args:
      - "-skipPackagePluginValidation"
      - "-quiet"
      - "OTHER_SWIFT_FLAGS=-D SKIP_FORMAT"

# gradle: disable the daemon and parallelism for a deterministic run
pre-push:
  test-override:
    type: gradle
    task: ":mobile:testDevelopDebugUnitTest"
    extra-args:
      - "--no-daemon"
      - "-Pci=true"

# swift: filter to a specific test
pre-push:
  test-override:
    type: swift
    extra-args:
      - "--filter"
      - "MyFeatureTests.someBehavior"
```

Args are passed through with no quoting/escaping. Each list element becomes one `argv` entry — so don't pre-quote things, just split on word boundaries (`["-foo", "bar"]`, not `["-foo bar"]`).

### Swift package test override

```yaml
pre-push:
  test-override:
    type: swift
```

## Glob pattern syntax

The `on-files` field supports these patterns:

| Pattern | Matches |
|---------|---------|
| `*.swift` | Any `.swift` file in any directory |
| `Sources/*.swift` | `.swift` files under `Sources/`, including nested paths |
| `Sources/**/*.swift` | `.swift` files anywhere under `Sources/` |
| `*.strings` | Any `.strings` file |
| `Tests/Fixtures/**/*.json` | JSON files anywhere under `Tests/Fixtures/` |

## Error handling

- **Missing config file (all locations)**: Not an error. The tool runs in zero-config mode.
- **Malformed YAML**: Error. The hook fails immediately with a parse error.
- **Non-dict YAML** (e.g. a plain string): Treated as empty config (graceful degradation).
- **Invalid regex in `pattern`**: Error. The hook fails immediately.
- **Unknown `test-override.type`**: Warning. The test override is ignored and auto-detection is used.
- **Malformed task (missing `name` or `run`)**: Warning. The task is skipped, other tasks still run.
- **Circular or missing `after` dependencies**: Error. The hook fails immediately because the task order cannot be resolved.
- **Projects-list with no matching pattern**: The file is skipped; resolution continues to the next priority level.
