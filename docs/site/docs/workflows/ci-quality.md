# ci-quality

Code quality and linting workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |

## Version matrix

The `lint` and `typecheck` matrix comes from
[`vrg-ci-resolve`](../actions/shared-setup-vergil.md) at run time: the
workflow's `matrix` job runs the shared setup action, which calls the resolver,
and passes its versions, image tags and image suffixes to
[`ci/matrix`](../actions/ci-matrix.md). Each leg pins uv to its version and to
the image's interpreter (Python, with
[`ci/toolchain/pin-python`](../actions/ci-toolchain-pin-python.md)) and then
asserts the running toolchain with
[`ci/toolchain/assert`](../actions/ci-toolchain-assert.md). The
single-container `common` job runs on the resolver's `primary-container-tag`.
Callers are thin: they pass only `language:` and `container-suffix:`.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `common` | `<caller> / common` | Runs common linters based on file presence (single-container job on the primary version) |
| `lint / <version>` | `<caller> / lint / <version>` | Language-specific linting (matrix-expanded — informational, not a required check) |
| `typecheck / <version>` | `<caller> / typecheck / <version>` | Language-specific type checking (matrix-expanded — informational, not a required check) |
| `evidence` | `quality / evidence` | Aggregate gate — `needs` the `common`, `lint`, and `typecheck` jobs, runs `if: always()`, and asserts each succeeded; a failed/skipped leg makes it **fail red** rather than skip. **This stable, version-agnostic gate is the required check** (see [Required Checks](../ci-gates/required-checks.md)) |

## Common checks

The `common` job runs inside a single container on the primary version —
`ghcr.io/vergil-project/<prefix>-<suffix>:<tag>`, where `<tag>` is the
resolver's `primary-container-tag`. It conditionally executes each
linter based on whether matching files exist in the repository:

| Tool | Condition |
| ------ | ----------- |
| markdownlint | `*.md` files found |
| shellcheck | `*.sh` files or `scripts/bin/` directory found |
| yamllint | `*.yml` or `*.yaml` files found |
| hadolint | `Dockerfile*` files found |
| actionlint | `.github/workflows/` directory found |

## Usage

```yaml
jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      container-suffix: python
```

## Extension points

The `lint` and `typecheck` jobs provide a version matrix scaffold. Consuming
repositories customize these jobs by forking the workflow or by running
language-specific tooling in a separate workflow that calls these as a
baseline.
