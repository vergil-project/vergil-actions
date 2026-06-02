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
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.0
    with:
      language: shell
      versions: '["latest"]'
      container-suffix: base

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.0
    permissions:
      contents: read
      security-events: write
    with:
      language: shell

  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.0
    with:
      language: shell
```

### ci.yml — Versioned language (full)

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
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.0
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'

  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.0
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'
      container-tag: '3.14'
      container-suffix: python

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.0
    permissions:
      contents: read
      security-events: write
    with:
      language: python
      run-standards: ${{ inputs.run-release != false }}
      run-security: ${{ inputs.run-security != false }}
      container-tag: '3.14'
      container-suffix: python

  test:
    uses: vergil-project/vergil-actions/.github/workflows/ci-test.yml@v2.0
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'

  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.0
    with:
      language: python
      run-release: ${{ inputs.run-release != false }}
      container-tag: '3.14'
      container-suffix: python
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
    uses: vergil-project/vergil-actions/.github/workflows/cd-docs.yml@v2.0
    permissions:
      contents: write

  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.0
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
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.0
    with:
      language: python
    secrets: inherit
```
