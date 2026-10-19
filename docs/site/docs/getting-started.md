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
      actions: read
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
    # Python publishes via OIDC trusted publishing — no secret to pass.
```

### Release publishing secrets

A repo **without** a `[package]` section in `vergil.toml` must forward only
the publishing credentials the target ecosystem needs, never a blanket
`secrets: inherit`. The generated `cd.yml` emits an explicit `secrets:` block
(or none at all) matching the language:

| Ecosystem | Secrets to forward |
| --------- | ------------------ |
| `python` | None — OIDC trusted publishing (requires `id-token: write`) |
| `go` | None |
| `rust` | `CARGO_REGISTRY_TOKEN` |
| `ruby` | `RUBYGEMS_API_KEY` |
| `java` | `CENTRAL_USERNAME`, `CENTRAL_TOKEN`, `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE` |

For example, a Rust release job forwards a single least-privilege secret:

```yaml
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: rust
    secrets:
      CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

A repo **with** a `[package]` section (one that publishes `.deb`/`.rpm`
binary packages) is the exception: it **must** pass `secrets: inherit`. Its
`package-sign` job reads `PACKAGE_SIGNING_KEY` and
`PACKAGE_SIGNING_PASSPHRASE` from the repo's main-only `package-signing`
environment, and environment secrets reach a cross-repo reusable workflow
only through `secrets: inherit`. An explicit `secrets:` map does not deliver
them, so the signing key arrives empty and `package-sign` fails (verified by
a controlled probe, vergil-project/packages#6). `inherit` also forwards
`APP_CLIENT_ID` and `APP_PRIVATE_KEY`, which the release uses to dispatch
the package index. Semgrep's `secrets-inherit` rule flags the line, so
suppress it there with the rule ID:

```yaml
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    permissions:
      contents: write
      id-token: write
      attestations: write
      actions: read
    with:
      language: rust
    # Required for [package] repos: environment secrets (package-signing)
    # only reach the reusable workflow with inherit.
    secrets: inherit  # nosemgrep: yaml.github-actions.security.secrets-inherit.secrets-inherit
```

See [CD Release: binary packages](workflows/cd-release-packages.md)
for the `package-signing` environment and the GitHub App setup.

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
