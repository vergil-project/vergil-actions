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
  codeql:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v6
      - uses: vergil-project/vergil-actions/actions/ci/security/codeql@v2.1
        with:
          language: python
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
      container-suffix: python

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
    # For the reporting job, which reports develop's docs deploys to the
    # org's operations queue as the automation App.
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}

  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
    # Python publishes via OIDC trusted publishing — no secret to pass.
```

### Org Actions variables

Besides the App secrets, the reusable workflows read two org-level Actions
variables, visible to all repositories, which the human publishes once per
org from the host configuration:

| Variable | Holds |
| -------- | ----- |
| `VRG_TRUSTED_AUTHORS` | The trusted-authors configuration, as compact JSON. Every step that runs a vergil-tooling command reading GitHub content gets it, and stops when it is missing or invalid |
| `VRG_AUTOMATION_APP` | The slug of the org's automation App |

Set them up in this order: add the org's `[orgs.<org>]` stanza to the host
configuration, install a vergil-tooling release that carries the trust
layer on the host, and run `vrg-trusted-authors publish --org <org>` right
away. `vrg-trusted-authors render --org <org>` previews the values with no
GitHub call. A job that runs that release before the variables are published
stops loudly; re-run it once they are. See
[VRG_TRUSTED_AUTHORS](configuration.md#vrg_trusted_authors) for details.

### Release publishing secrets

Every release forwards the org automation App's `APP_CLIENT_ID` and
`APP_PRIVATE_KEY`: the release tags are pushed with the App's installation
token, and a release without them fails before anything is published or
tagged ([CD Release: secrets](workflows/cd-release.md#secrets)).

A repo **without** a `[package]` section in `vergil.toml` must forward only
those and the publishing credentials the target ecosystem needs, never a
blanket `secrets: inherit`, in an explicit `secrets:` block:

| Ecosystem | Publishing secrets to forward |
| --------- | ----------------------------- |
| `python` | None — OIDC trusted publishing (requires `id-token: write`) |
| `go` | None |
| `rust` | `CARGO_REGISTRY_TOKEN` |

For example, a Rust release job forwards the App secrets and one
least-privilege publishing secret:

```yaml
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: rust
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
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
`APP_CLIENT_ID` and `APP_PRIVATE_KEY`, which the release uses to push the
tags and dispatch the package index. Semgrep's `secrets-inherit` rule flags the line, so
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
| `contents: read` | All actions (repository checkout) |
| `contents: write` | cd/docs/deploy, cd/release/tag-and-release |
| `security-events: write` | security/codeql, security/semgrep, security/trivy |

## Self-referencing CI

This repository uses **local paths** (`./actions/...`) rather than remote
references in its own CI workflow. This means changes to an action are validated
by the same PR that modifies them — no separate integration testing step is
needed.

Consuming repositories use the full remote reference
(`vergil-project/vergil-actions/actions/...@v2.1`).
