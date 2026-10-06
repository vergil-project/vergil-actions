# Reusable Workflows

v2.0.0 introduced reusable CI workflows that provide canonical job and check
names across all managed repositories. Each workflow bundles one or more
composite actions with the container, tooling, and permission setup needed
to run them. CD workflows handle post-merge delivery (releases, documentation).

## Why reusable workflows?

Composite actions run as steps within a caller-defined job. Reusable workflows
run as complete jobs, which means they control the job name that appears in
GitHub's checks UI. This guarantees consistent, canonical check names across
repositories — a requirement for pattern-based required status checks in
rulesets.

## CI workflows (pre-merge)

| Workflow | File | Purpose |
| ---------- | ------ | --------- |
| [CI Docs](ci-docs.md) | `ci-docs.yml` | Build-only MkDocs strict verification (no deploy) |
| [CI Security](ci-security.md) | `ci-security.yml` | Standards compliance and security scanning |
| [CI Quality](ci-quality.md) | `ci-quality.yml` | Common linting, language-specific lint and typecheck |
| [CI Audit](ci-audit.md) | `ci-audit.yml` | Dependency audit |
| [CI Test](ci-test.md) | `ci-test.yml` | Unit and integration tests |
| [CI Version Bump](ci-version-bump.md) | `ci-version-bump.yml` | Version divergence gate |

## CD workflows (post-merge)

| Workflow | File | Purpose |
| ---------- | ------ | --------- |
| CD Release | `cd-release.yml` | Full release pipeline (tag, build, publish, version bump) |
| CD Docs | `cd-docs.yml` | MkDocs documentation deployment |
| Publish package index | `publish-index.yml` | Signed apt/dnf package-repository site, deployed to Pages |

### CD Release: binary packages

When the caller's `vergil.toml` has a `[package]` section, `cd-release.yml`
also builds, signs and attaches the repo's `.deb`/`.rpm` packages:

| Job | Behavior |
| --- | -------- |
| `package-matrix` | Always runs. `vrg-package matrix --github-output --manifest packages-manifest.json` resolves the build cells and writes the release manifest. |
| `package-build / <cell>` | One job per build cell, on the cell's runner inside its build OS image, with the same toolchain as `ci-package.yml`. The packages are unsigned. |
| `package-sign` | Declares the `package-signing` environment. It signs every `.rpm` with the org signing subkey and verifies each signature, then attests the provenance of every package. |
| `release` | Runs only if `package-sign` succeeded. It attaches the signed packages and `packages-manifest.json` to the Release, then dispatches `package-released` to `<owner>/packages`. |

A failed build cell or signing step stops `release` before anything is
published or tagged. The dispatch is deferred: if minting the App token or the
dispatch fails, the release still stands. The index's weekly reconcile picks
it up, and `vrg-release` reports the miss. Repos without `[package]` see only
the extra `package-matrix` job. The other package jobs are skipped, and they
never reference the `package-signing` environment.

A packaged repo needs:

- **A `package-signing` environment.** Its deployment-branch policy must admit
  only `main`. It holds the `PACKAGE_SIGNING_KEY` secret (the ASCII-armored
  export of the signing subkey) and `PACKAGE_SIGNING_PASSPHRASE`. If the key
  is missing or empty, `package-sign` fails.
- **`secrets: inherit` on the caller (required).** Environment secrets reach
  a job in a cross-repo reusable workflow **only** when the caller passes
  `secrets: inherit`. An explicit `secrets:` map, or passing nothing, delivers
  an empty value; declaring the secret in the callee makes no difference
  (verified by a controlled probe, vergil-project/packages#6). Semgrep's
  `secrets-inherit` rule flags this, so suppress it on that line with a
  justification (`# nosemgrep: …`; honored by the SARIF gate since
  vergil-project/vergil-tooling#3107). `inherit` also forwards the org App
  secrets `APP_CLIENT_ID` and `APP_PRIVATE_KEY`, which the index dispatch
  needs. The App must be installed on
  `<owner>/packages` with permission to create repository dispatches
  (`contents: write`).
- **The same permissions the release job already needs.** The package jobs
  request only `contents: read`, `id-token: write` and `attestations: write`:

```yaml
jobs:
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    permissions:
      contents: write
      id-token: write
      attestations: write
      actions: read
    with:
      language: python
    # Required: environment secrets only reach the reusable workflow with inherit.
    secrets: inherit  # nosemgrep: yaml.github-actions.security.secrets-inherit.secrets-inherit
```

### Publish package index

`publish-index.yml` is called from an `<org>/packages` repository. Its
`build-index` job runs `vrg-package index --config packages.toml --keys keys
--out _site`, which verifies, retains, indexes and signs the product releases.
Its `deploy` job then publishes the site with the Actions-based Pages deploy.
The workflow takes no inputs. Runs are serialized by the `publish-index`
concurrency group. Unlike the other reusable workflows, it runs directly on
`ubuntu-latest` rather than in a vergil container image.

The signing key comes from the caller repository's `index-signing`
environment, which must admit only `develop` and hold `PACKAGE_SIGNING_KEY`
and `PACKAGE_SIGNING_PASSPHRASE`. As with `cd-release`, those environment
secrets reach the reusable workflow only when the caller passes
`secrets: inherit` (see above). The caller must also grant the scopes the two
jobs request:

```yaml
jobs:
  publish-index:
    uses: vergil-project/vergil-actions/.github/workflows/publish-index.yml@v2.1
    permissions:
      contents: read
      attestations: read
      pages: write
      id-token: write
    # Required: environment secrets only reach the reusable workflow with inherit.
    secrets: inherit  # nosemgrep: yaml.github-actions.security.secrets-inherit.secrets-inherit
```

## Dynamic version matrix and evidence gates

The matrixed CI workflows (`ci-audit`, `ci-quality`, `ci-test`) derive their
version matrix from `[ci].versions` in the consumer's `vergil.toml` at run time,
via the shared setup action's `versions` / `primary-version` outputs. A
consumer's `ci.yml` is therefore a **thin caller** that passes only `language:`
and `container-suffix:` — it no longer passes `versions:` or `container-tag:`.
Those two inputs are still accepted for back-compat but are deprecated and
slated for removal (see each workflow's inputs table and
[#876](https://github.com/vergil-project/vergil-actions/issues/876)).

Single-container workflows (`ci-security`, `ci-version-bump`, `ci-docs`) run on
the primary version = `[ci].primary-version` if set, else the highest
`[ci].versions` entry (family-routed to the published container tag for `cpp`).

Each matrixed workflow emits a stable, version-agnostic aggregate gate named
`<kind> / evidence` — `audit / evidence`, `quality / evidence`, and
`test / evidence`. The evidence job `needs` every matrix leg and runs with
`if: always()`, asserting each leg's result is `success`, so a failed or skipped
leg makes the aggregate **fail red** rather than skip green. Branch protection
requires these stable evidence gates, not the per-version legs, so the
required-check set does not churn when `[ci].versions` changes. See
[Required Checks](../ci-gates/required-checks.md).

## Consuming a reusable workflow

Reference workflows using the full path to the workflow file with a rolling
minor tag pin:

```yaml
uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
```

!!! note "Tag pinning"
    The same tag pinning guidance applies as for composite actions. Pin to
    `@v2.1` for automatic patch releases, or `@v2.1.0` for full
    reproducibility.

## Permissions

Reusable workflows inherit permissions from the calling workflow. Callers must
declare the permissions each workflow needs at the job level:

```yaml
jobs:
  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      language: python
```

A called workflow's own `permissions:` blocks are **requests against the
caller**: GitHub validates at workflow startup that the calling job's
effective permissions cover every requested scope, and rejects the run with
`startup_failure` if they do not. See each workflow's page for the scopes
it requests.

## Container image prefix

All reusable workflows run inside container images from the
`ghcr.io/vergil-project/` registry. The image name follows the pattern:

```text
ghcr.io/vergil-project/<prefix>-<suffix>:<tag>
```

The **prefix** defaults to `prod` and selects which image variant to use.
Every reusable workflow accepts a `container-prefix` input that overrides
this default. The Docker images are part of the development and deployment
environment only — there is no runtime dependency on them from the
artifacts these workflows produce.

### Overriding the prefix

To test against development Docker images, pass `container-prefix: dev`
to the reusable workflow calls in the consumer's `ci.yml`, `cd.yml`, or
`ops.yml`. Override a single workflow call to test one phase, or override
all calls in a file to run the full CI/CD pipeline against dev images.

**Single workflow override:**

```yaml
jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      container-suffix: python
      container-prefix: dev
```

**Full CI file override** (add `container-prefix: dev` to every call):

```yaml
jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      container-suffix: python
      container-prefix: dev

  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    with:
      language: python
      container-prefix: dev

  test:
    uses: vergil-project/vergil-actions/.github/workflows/ci-test.yml@v2.1
    with:
      language: python
      container-suffix: python
      container-prefix: dev
```

Committing and pushing the overrides is expected when running a full
end-to-end integration test of the dev images through CI and CD. Remove
the overrides once the dev images have been validated and promoted to
prod.

For local validation using development containers, see the
[`vrg-container-run` documentation](https://vergil-project.github.io/vergil-tooling/reference/cli-tools-overview/#vrg-container-run)
for instructions on specifying the container prefix.

## Reference freezing

The workflow source files reference composite actions via `@develop` during
development. At release time, the publish workflow freezes all `@develop`
references to the release tag (e.g., `@v2.1.0`), ensuring that a pinned
workflow version uses the matching action versions.
