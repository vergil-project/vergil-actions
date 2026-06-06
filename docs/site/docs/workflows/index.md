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
      versions: '["3.12", "3.13", "3.14"]'
      container-prefix: dev
```

**Full CI file override** (add `container-prefix: dev` to every call):

```yaml
jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'
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
      versions: '["3.12", "3.13", "3.14"]'
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
