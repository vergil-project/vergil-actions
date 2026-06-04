# Getting Started

## Consuming actions

Reference actions from this repository using the full path with a rolling minor
tag pin:

```yaml
uses: vergil-project/vergil-actions/actions/<action-path>@v2.1
```

!!! note "Tag pinning"
    Pin to a rolling minor tag (e.g., `@v2.1`) to automatically receive patch
    releases. Pin to an exact tag (e.g., `@v2.1.1`) for full reproducibility.

## Minimal workflow example

```yaml
name: CI - Test and Validate

on:
  pull_request:

permissions:
  contents: read

jobs:
  standards:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: vergil-project/vergil-actions/actions/ci/security/standards-compliance@v2.1
```

## Consuming reusable workflows

Reusable workflows produce canonical check names across all repositories.
Reference workflows using the full path to the workflow file:

```yaml
uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
```

### CI workflow example

```yaml
name: CI

on:
  pull_request:

permissions:
  contents: read
  security-events: write

jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
    with:
      language: python
```

### CD workflow example

```yaml
name: CD

on:
  push:
    branches: [develop, main]

permissions:
  contents: write
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

See [Reusable Workflows](workflows/index.md) for the full list and
detailed documentation.

## Permissions

Each action documents its required workflow permissions. Common patterns:

| Permission | Actions that require it |
| ------------ | ---------------------- |
| `contents: read` | standards-compliance |
| `contents: write` | docs-deploy, publish/tag-and-release |
| `security-events: write` | security/codeql, security/semgrep, security/trivy |

## Self-referencing CI

This repository uses **local paths** (`./actions/...`) rather than remote
references in its own CI workflow. This means changes to an action are validated
by the same PR that modifies them — no separate integration testing step is
needed.

Consuming repositories use the full remote reference
(`vergil-project/vergil-actions/actions/...@v2.1`).
