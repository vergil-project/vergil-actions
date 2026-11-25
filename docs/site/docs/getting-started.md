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
      contents: read
    # The docs job deploys gh-pages, and the report job reports develop's
    # deploys to the org's operations queue, as the automation App. `inherit`
    # within the org: it carries the App keys from the `automation`
    # environment. A caller in another org passes APP_CLIENT_ID and
    # APP_PRIVATE_KEY by name, since `inherit` reaches only a reusable
    # workflow in the caller's own organization or enterprise.
    secrets: inherit

  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
    # Every release pushes its tags as the automation App. `inherit` within
    # the org: it carries the App keys from the `automation` environment.
    # Python publishes via OIDC trusted publishing, so no publishing secret is
    # needed. A caller in another org passes APP_CLIENT_ID and APP_PRIVATE_KEY
    # by name (see Release publishing secrets below).
    secrets: inherit
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

Every release needs the org automation App's `APP_CLIENT_ID` and
`APP_PRIVATE_KEY`: the release tags are pushed with the App's installation
token, and a release without them fails before anything is published or
tagged ([CD Release: secrets](workflows/cd-release.md#secrets)). The keys
live in the repo's `automation` environment, and the release job passes them
on by one of two routes, as `vrg-github-repo-init` generates it.

**Within vergil-project**, the release job passes `secrets: inherit`. It
carries the App keys and every other secret the release reads: the
publishing credential the ecosystem needs and, for a repo with a `[package]`
section (one that publishes `.deb`/`.rpm` binary packages), the
`PACKAGE_SIGNING_KEY` and `PACKAGE_SIGNING_PASSPHRASE` that its
`package-sign` job reads from the repo's main-only `package-signing`
environment. vrg-validate's secrets-inherit check allows `inherit` only to
the vergil-actions workflows that read such secrets, `cd-release.yml` among
them:

```yaml
  release:
    if: github.ref == 'refs/heads/main' && !github.event.created
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: rust
    secrets: inherit
```

**Across organizations**, `secrets: inherit` passes nothing, so the release
job passes the App keys by name, with the publishing credential the
ecosystem needs:

| Ecosystem | Publishing secrets to pass |
| --------- | -------------------------- |
| `python` | None — OIDC trusted publishing (requires `id-token: write`) |
| `go` | None |
| `rust` | `CARGO_REGISTRY_TOKEN` |

```yaml
  release:
    if: github.ref == 'refs/heads/main' && !github.event.created
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: rust
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
      CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

A `[package]` repo outside vergil-project cannot sign its packages yet: the
generated release job does not pass the signing secrets
([vergil-project/.github#1592](https://github.com/vergil-project/.github/issues/1592)).

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
