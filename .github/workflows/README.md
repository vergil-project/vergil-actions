# Workflow Conventions

Canonical reference for workflow file naming, formatting, and structure
across all managed repositories.

## Naming Convention

| Pattern | Role | Trigger |
|---|---|---|
| `ci.yml` | Local CI umbrella | `pull_request` |
| `ci-*.yml` | Reusable pre-merge gate | `workflow_call` |
| `cd.yml` | Local CD umbrella | `push` to main/develop |
| `cd-*.yml` | Reusable post-merge delivery | `workflow_call` |

**Bare name** (`ci.yml`, `cd.yml`) = local entry point.
**Hyphenated** (`ci-quality.yml`, `cd-release.yml`) = reusable workflow.

## Available Reusable Workflows

### CI (pre-merge)

| Workflow | Purpose |
|---|---|
| `ci-docs.yml` | Build-only MkDocs strict verification (no deploy) |
| `ci-quality.yml` | Common linting, language-specific lint and typecheck |
| `ci-security.yml` | Standards compliance and security scanning |
| `ci-test.yml` | Unit and integration tests |
| `ci-audit.yml` | Dependency audit |
| `ci-version-bump.yml` | Version divergence gate |

### CD (post-merge)

| Workflow | Purpose |
|---|---|
| `cd-release.yml` | Full release pipeline (tag, build, publish, version bump) |
| `cd-docs.yml` | MkDocs documentation deployment |

## Formatting Rules

### File-level structure (top to bottom)

1. Reference comment (consumer repos only — see below)
2. `name:`
3. `on:`
4. `permissions:` (if needed at workflow level)
5. `concurrency:` (if needed)
6. `jobs:` — entries in **alphabetical order** by job key

### Job ordering

Alphabetical by job key. Always. No exceptions.

### Comments

- No section banners or decorative separators.
- No redundant labels that restate the job key.
- Comments only when the YAML itself does not convey intent (e.g.,
  a workaround, a non-obvious constraint).
- No `# yamllint disable-line` pragmas — fix the YAML instead.

### Whitespace

- One blank line between top-level keys (`on:`, `permissions:`, `jobs:`).
- One blank line between jobs within the `jobs:` block.
- No trailing blank lines at end of file.

### Reference comment

Every consuming repo's workflow files include on line 1:

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
```

Rules:
- Line 1, always — before `name:`.
- Just the raw URL, no surrounding prose.
- Points to the `develop` branch.
- standard-actions' own workflow files skip this (README is co-located).

### Standardized `workflow_call` inputs

- Boolean toggles use `type: boolean` (not `type: string`).
- Version matrix input is always named `versions` (not `go-versions`,
  `ruby-versions`, etc.).
- **`versions` and `container-tag` are optional and no longer the way to
  set the matrix or the single-container tag.** The matrixed workflows
  (`ci-audit`, `ci-quality`, `ci-test`) derive the version matrix from
  `[ci].versions` in the consumer's `vergil.toml`, and the single-container
  jobs resolve their image tag from `[ci].primary-version` (default: the
  highest `[ci].versions` entry). Both inputs are still **accepted** for
  back-compat — a supplied value is honored verbatim — but they are
  deprecated and slated for removal once no consumer passes them (epic
  [vergil-project/.github#338](https://github.com/vergil-project/.github/issues/338),
  removal tracked in
  [#876](https://github.com/vergil-project/vergil-actions/issues/876)). New
  and updated `ci.yml` callers should omit them.

## Dynamic version matrix and evidence gates

The matrixed reusable workflows (`ci-audit`, `ci-quality`, `ci-test`) read
`[ci].versions` from the consumer's `vergil.toml` at run time — via the shared
setup action's `versions` / `primary-version` outputs — and derive the job
matrix themselves. A consumer's `ci.yml` is therefore a **thin caller** that
passes only `language:` and `container-suffix:`; it no longer passes
`versions:` or `container-tag:`.

Each matrixed workflow emits a stable, version-agnostic aggregate gate named
`<kind> / evidence` — `audit / evidence`, `quality / evidence`, and
`test / evidence`. The evidence job `needs` every matrix leg and runs with
`if: always()`, asserting `needs.<leg>.result == 'success'`, so a failed or
skipped leg makes the aggregate **fail red** rather than skip green. Branch
protection requires these stable evidence gates, not the per-version legs —
so the required-check set does not churn when `[ci].versions` changes.

Single-container workflows (`ci-security`, `ci-version-bump`, `ci-docs`) run on
the primary version = `[ci].primary-version` if set, else the highest
`[ci].versions` entry (family-routed to the published container tag for
`cpp`).

## Examples

### ci.yml — Shell (no version matrix)

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
name: CI

on:
  pull_request:

permissions:
  contents: read
  security-events: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: shell
      container-suffix: base

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
    with:
      language: shell

  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.1
    with:
      language: shell
```

### ci.yml — Versioned language (full)

The matrix and the single-container image tag both come from `[ci]` in the
consumer's `vergil.toml`, so the caller passes only `language:` and
`container-suffix:` — no `versions:` or `container-tag:`:

```toml
# vergil.toml
[ci]
versions = ["3.12", "3.13", "3.14"]
# primary-version defaults to the highest entry (3.14) when unset
```

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
name: CI

on:
  pull_request:
  workflow_call:
    inputs:
      run-security:
        type: boolean
        default: true
      run-release:
        type: boolean
        default: true

permissions:
  contents: read
  security-events: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: python
      container-suffix: python

  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      container-suffix: python

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
    with:
      language: python
      run-security: ${{ inputs.run-security != false }}
      container-suffix: python

  test:
    uses: vergil-project/vergil-actions/.github/workflows/ci-test.yml@v2.1
    with:
      language: python
      container-suffix: python

  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.1
    with:
      language: python
      run-release: ${{ inputs.run-release != false }}
      container-suffix: python
```

### ci.yml — C++ (compiler-family matrix)

C++ carries its compiler family × version axis on `[ci].versions` in
`vergil.toml` as `clang-`/`gcc-` prefixed tokens. The reusable workflows read
that set, split each token, and route it to the matching image —
`clang-20` → `prod-cpp-clang:20`, `gcc-14` → `prod-cpp-gcc:14` — via the
`actions/ci/matrix` resolver. The caller still passes `container-suffix:`
(`cpp-clang`) for the non-matrix `common` job; it no longer passes `versions:`
or `container-tag:`, which the workflows derive from `[ci]` (the single-container
tag is the family-routed `primary-container-tag` from `[ci].primary-version`).

Per-kind cardinality follows the gate model: `typecheck` and `unit` run
per compiler×version (one job/gate each), while `lint` and `dependencies` run
once on the primary (Clang) image. The emitted gate names line up with
`github_config.desired_ci_gates_ruleset` for a cpp repo — e.g.
`quality / lint / clang-20` (once), `quality / typecheck / clang-20`,
`quality / typecheck / gcc-14`, `test / unit / gcc-13`,
`audit / dependencies / clang-20` (once).

The compiler-family × version tokens live in `vergil.toml`:

```toml
# vergil.toml
[ci]
versions = ["clang-20", "clang-19", "gcc-14", "gcc-13"]
# primary-version defaults to the highest entry (clang-20) when unset
```

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
name: CI

on:
  pull_request:

permissions:
  contents: read
  security-events: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: cpp
      container-suffix: cpp-clang
    # Explicit-secret chain (never `secrets: inherit`): forward the ConanCenter
    # provider token so `conan audit` can authenticate. Optional — omit it and
    # the cpp audit command skips the conan gate with a notice.
    secrets:
      CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER: ${{ secrets.CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER }}

  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: cpp
      container-suffix: cpp-clang

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
    with:
      language: cpp
      container-suffix: cpp-clang

  test:
    uses: vergil-project/vergil-actions/.github/workflows/ci-test.yml@v2.1
    with:
      language: cpp
      container-suffix: cpp-clang

  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.1
    with:
      language: cpp
      container-suffix: cpp-clang
```

### cd.yml — Release + Docs

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
name: CD

on:
  push:
    branches: [develop, main]
  workflow_dispatch:

permissions:
  attestations: write
  contents: write
  id-token: write
  pull-requests: write

jobs:
  docs:
    uses: vergil-project/vergil-actions/.github/workflows/cd-docs.yml@v2.1
    permissions:
      contents: write

  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
    secrets: inherit
```

### cd.yml — Release only (no docs)

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
name: CD

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  attestations: write
  contents: write
  id-token: write
  pull-requests: write

jobs:
  release:
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
    secrets: inherit
```
