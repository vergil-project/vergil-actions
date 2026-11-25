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
| `ci-quality.yml` | Common linting, custom validation, language-specific lint and typecheck |
| `ci-security.yml` | Security scanning (CodeQL, Trivy, Semgrep) |
| `ci-test.yml` | Unit and integration tests |
| `ci-audit.yml` | Dependency audit |
| `ci-version-bump.yml` | Version divergence gate |
| `ci-package.yml` | Build and install-test `.deb`/`.rpm` packages (repos with `[package]` only; gate `package / evidence`; `package-tier` input: `auto`/`full`/`reduced`, auto = full on same-repository release PRs and non-PR events, reduced on other PRs (a fork's `release/*` head included); `container-prefix` input: `prod` (default) or `dev`, runs the build and install-test jobs on the `<prefix>-pkg-*` images) |

### CD (post-merge)

| Workflow | Purpose |
|---|---|
| `cd-release.yml` | Full release pipeline (tag, build, publish, version bump). Repos with `[package]` also build their `.deb`/`.rpm` packages, sign the `.rpm`s in the main-only `package-signing` environment, attest them, attach them (plus `packages-manifest.json`) to the Release, and dispatch `package-released` to `<owner>/packages`; such callers must pass `secrets: inherit`. `container-prefix` input: `prod` (default) or `dev`, picks the release job's image and runs the `package-build` cells on the `<prefix>-pkg-*` images |
| `cd-docs.yml` | MkDocs documentation deployment. Its `docs` job, in the `automation` environment, pushes `gh-pages` with a Contents-write App token, so the caller grants only `contents: read`. Its `report` job, in the `automation` environment, reports a develop deploy to the org's operations queue as `docs-deploy-develop` with the App keys `APP_CLIENT_ID` and `APP_PRIVATE_KEY` (`report: false` turns it off); a caller in the same org passes `secrets: inherit`, one in another org passes the two keys by name |
| `publish-index.yml` | Rebuild, verify and sign the apt/dnf package-repository site from the releases in `packages.toml` and deploy it to GitHub Pages, then fail within minutes unless Pages serves the index just built (called only from an `<org>/packages` repo; `index-signing` environment, develop only; caller passes `secrets: inherit`) |

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
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md
```

Rules:
- Line 1, always — before `name:`.
- Just the raw URL, no surrounding prose.
- Points to the `develop` branch.
- vergil-actions' own workflow files skip this (README is co-located).

### Standardized `workflow_call` inputs

- Boolean toggles use `type: boolean` (not `type: string`).
- The CI workflows take no version inputs. The `versions` and
  `container-tag` inputs were removed in
  [#899](https://github.com/vergil-project/vergil-actions/pull/899): the
  matrix and every image tag come from `vrg-ci-resolve`, run by the shared
  setup action (`actions/shared/setup/vergil`), and the primary version is
  `[ci].primary-version` or, without it, the newest resolved version. A
  caller passes only `language:` and `container-suffix:`.
- A composite action that takes a version list names it `versions` (not
  `go-versions`, `python-versions`, etc.), as `actions/ci/matrix` does.
- Every reusable workflow that runs a job in a `ghcr.io/vergil-project`
  image declares `container-prefix` (`type: string`, `required: false`,
  `default: prod`) and takes every such image's prefix from it: a
  `ghcr.io/vergil-project/${{ inputs.container-prefix || 'prod' }}-…`
  container line, a matrix image from `actions/ci/matrix` or
  `actions/package/image-prefix` given the input, or the input passed on to
  a called workflow. No reusable workflow names a `prod-` image literally,
  and each file reads only its own input, so a caller sets its CI and its
  release separately
  ([#1134](https://github.com/vergil-project/vergil-actions/issues/1134);
  `actions/shared/setup/primary-suffix/tests/container-prefix.test.sh`
  checks it).

## The `automation` environment

Every job that reads a secret able to write or act declares
`environment: automation`. Those secrets are the org automation App's
`APP_CLIENT_ID` and `APP_PRIVATE_KEY`, which mint an installation token, and
the registry publishing tokens such as `CARGO_REGISTRY_TOKEN`. The job's steps
are unchanged.

Why: the secrets move from org and repository level into each repository's
`automation` environment, whose deployment-branch policy admits only
`develop` and `main` (epic
[vergil-project/.github#1384](https://github.com/vergil-project/.github/issues/1384)).
A job that does not declare the environment, or that runs from any other
branch, then sees them unset, so a workflow pushed on a feature branch cannot
mint the App token or publish. A job declaring the environment on another
branch is refused before any step runs.

- The package-signing keys keep their own single-branch environments
  (`package-signing`, `index-signing`), so a signing job declares that
  environment, never `automation`.
- A job that reads a secret with no environment reads only a read-only
  one: the run's own `GITHUB_TOKEN`, or
  `CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER`, a read-only vulnerability
  database key that PR-time CI reads for the C/C++ audit.
- A calling job cannot declare an environment, so a caller of an App-key
  workflow passes the keys on, and they reach the called workflow's jobs
  that declare `environment: automation`. Within vergil-project the caller
  passes `secrets: inherit`, which vrg-validate's secrets-inherit check
  allows only to the App-key workflows. GitHub passes `inherit` only to a
  reusable workflow in the caller's own organization or enterprise, so a
  caller in another org passes `APP_CLIENT_ID` and `APP_PRIVATE_KEY` by
  name, as `vrg-github-repo-init` generates it.

`scripts/bin/check-secret-environments`, run by validation, fails on a job
that reads such a secret outside its environment, and on any secret it does
not classify.

## Dynamic version matrix and evidence gates

The matrixed reusable workflows (`ci-audit`, `ci-quality`, `ci-test`) take
their matrix from `vrg-ci-resolve` at run time. The shared setup action runs
the resolver, which reads the consumer's `vergil.toml` and the language
version window that vergil-containers publishes, and applies every rule: a
`library` builds the whole window, any other repository type is an app that
builds one version (an app pin of more than one version is an error), a
language whose window has more than one family (today only C++) must pin
`[ci].versions`, and a pin must lie inside the window.
Its versions, image tags and image suffixes feed `actions/ci/matrix`. Each
leg then pins its toolchain (Python legs with `actions/ci/toolchain/pin-python`,
then install their dev dependencies with `actions/ci/toolchain/install-python`)
and asserts it with `actions/ci/toolchain/assert`. A consumer's `ci.yml` is
therefore a **thin caller** that passes only `language:` and
`container-suffix:`.

Each matrixed workflow emits a stable, version-agnostic aggregate gate named
`<kind> / evidence` — `audit / evidence`, `quality / evidence`, and
`test / evidence`. The evidence job `needs` every matrix leg and runs with
`if: always()`, asserting `needs.<leg>.result == 'success'`, so a failed or
skipped leg makes the aggregate **fail red** rather than skip green. Branch
protection requires these stable evidence gates, not the per-version legs.
The legs change whenever the resolved set changes (the window gains or drops a
version, or the `[ci].versions` pin changes); the required-check set does not.

`quality / evidence` always bundles the `common` job's transcript
(`quality-common.log`), so a language-less repo (no lint/typecheck reports)
still ships a real quality report rather than an `evidence.json`-only payload
that release-time harvest would reject (#925). It also bundles the `custom`
job's transcript (`quality-custom.log`, the `vrg-validate --check custom`
output): the repo's custom validator, or one "no custom validator" line when
it has none. `quality / evidence` needs `custom`, so a failed or skipped
custom stage fails the gate (epic vergil-project/.github#488).

Single-container jobs take their image differently:

- `ci-quality`'s `common` and `custom` jobs and `ci-version-bump` run on the
  primary version (`[ci].primary-version`, else the newest resolved
  version), at the image tag the resolver gives for it (`clang-20` runs on
  tag `20`). There is no family routing in the workflows: the resolver
  supplies the tag.
- `ci-security`'s Semgrep job and `ci-docs` run on `prod-base:latest`, which
  has no per-version tags. Docs jobs set `UV_PYTHON_PREFERENCE=only-system`,
  so uv uses the image's interpreter.
- `ci-security`'s CodeQL and Trivy jobs run on the bare runner, with no
  container.

## Examples

### ci.yml — Shell (no version matrix)

```yaml
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md
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

The matrix and the single-container image tag both come from
`vrg-ci-resolve`, so the caller passes only `language:` and
`container-suffix:`. A library leaves `[ci].versions` out and builds the whole
Python window, so a new window version is picked up without a config change:

```toml
# vergil.toml
[project]
repository-type = "library"
primary-language = "python"

# No [ci].versions: a library builds every version in the window.
# [ci].primary-version is optional; without it the primary is the newest
# resolved version.
```

An app (any other `repository-type`) builds one version: the newest in the
window, or a single-entry `[ci].versions` pin. Pinning an app to more than one
version is an error.

```yaml
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md
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

C++ carries its compiler family × version axis as `clang-`/`gcc-` prefixed
tokens, and its window has more than one family, so there is no single
default: it must pin `[ci].versions` in `vergil.toml`. `vrg-ci-resolve`
checks the pin against the window and gives each token its image suffix and
tag. `actions/ci/matrix` only joins them into an image —
`clang-20` → `prod-cpp-clang:20`, `gcc-14` → `prod-cpp-gcc:14` — with no
routing of its own. The caller still passes `container-suffix:` (`cpp-clang`), but
only as a cross-check: the `common` job requires it to equal the primary
version's resolved suffix, and the matrix accepts any of the resolved
suffixes. `ci-security` ignores `container-suffix` (a deprecated no-op), so its call
omits it.

Per-kind cardinality: `typecheck` and `unit` run per compiler×version, while
`lint` and `dependencies` run once, on the primary version. The legs are
informational, for example `quality / lint / clang-20` (once),
`quality / typecheck / clang-20`, `quality / typecheck / gcc-14`,
`test / unit / gcc-14` and `audit / dependencies / clang-20` (once). The
required checks are the `*/evidence` gates.

A pin of more than one version is valid only for a library; an app pins one
token:

```toml
# vergil.toml
[project]
repository-type = "library"
primary-language = "cpp"

[ci]
versions = ["clang-20", "clang-19", "gcc-14"]
# primary-version defaults to the newest resolved version (clang-20) when unset
```

```yaml
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md
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
    # provider token so `conan audit` can authenticate. A cpp caller must pass
    # it: omit it and the cpp audit command fails the conan gate.
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
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md
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
      contents: read
    # The docs job deploys gh-pages, and the report job reports develop's
    # deploys, as the automation App. `inherit` within the org: it carries the
    # App keys from the `automation` environment. A caller in another org
    # passes APP_CLIENT_ID and APP_PRIVATE_KEY by name, since `inherit`
    # reaches only a reusable workflow in the caller's own organization or
    # enterprise.
    secrets: inherit

  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
    # Every release pushes its tags as the automation App. `inherit` within
    # the org: it carries the App keys from the `automation` environment and
    # any publishing secret the ecosystem needs (Python publishes via OIDC,
    # so it needs none).
    secrets: inherit
```

A release job in another org passes the App keys by name, with
`CARGO_REGISTRY_TOKEN` for a Rust registry publish
([Release publishing secrets](../../docs/site/docs/getting-started.md#release-publishing-secrets)):

```yaml
    # By name, not inherit: GitHub passes `secrets: inherit` only to a
    # reusable workflow in the caller's own organization or enterprise.
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
      # For a Rust registry publish only:
      CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

### cd.yml — Release only (no docs), packaged repo

A repo with a `[package]` section passes `secrets: inherit`. It carries the
App keys and the `package-signing` environment's `PACKAGE_SIGNING_KEY` and
`PACKAGE_SIGNING_PASSPHRASE`, which `cd-release.yml` does not declare. A
`[package]` repo outside vergil-project cannot sign its packages yet
([vergil-project/.github#1592](https://github.com/vergil-project/.github/issues/1592)).

```yaml
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md
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
    # `inherit` within vergil-project: it carries the App keys and the
    # package-signing secrets. Allowed only for the App-key workflows
    # (vrg-validate's secrets-inherit check).
    secrets: inherit
```
