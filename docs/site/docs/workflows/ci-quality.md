# ci-quality

Code quality and linting workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `container-suffix` | string | no | `""` | Cross-check only. Every image suffix comes from the resolver. A non-empty value must equal the primary version's resolved suffix (e.g. `python`, `cpp-clang`, `base`), or `setup` fails. It never changes an image. |

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
single-container `common` job runs on the resolver's image for the primary
version (see [Common checks](#common-checks)). Callers are thin: they pass
only `language:`, and optionally `container-suffix:` as a cross-check.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `common` | `<caller> / common` | Runs common linters based on file presence (single-container job on the primary version) |
| `lint / <version>` | `<caller> / lint / <version>` | Language-specific linting (matrix-expanded — informational, not a required check) |
| `typecheck / <version>` | `<caller> / typecheck / <version>` | Language-specific type checking (matrix-expanded — informational, not a required check) |
| `evidence` | `quality / evidence` | Aggregate gate — `needs` the `common`, `lint`, and `typecheck` jobs, runs `if: always()`, and asserts each succeeded; a failed/skipped leg makes it **fail red** rather than skip. **This stable, version-agnostic gate is the required check** (see [Required Checks](../ci-gates/required-checks.md)) |

## Common checks

The `common` job runs inside a single container on the primary version —
`ghcr.io/vergil-project/<prefix>-<suffix>:<tag>`, the image the primary
`lint` and `typecheck` legs run on. The `setup` job resolves both parts with
the shared [setup action](../actions/shared-setup-vergil.md): `<tag>` is its
`primary-container-tag`, and `<suffix>` is the primary version's entry in its
`container-suffixes`, picked by
[shared/setup/primary-suffix](../actions/shared-setup-primary-suffix.md). For
example `clang-20` gives `prod-cpp-clang:20`, `3.14` gives
`prod-python:3.14` and a language-less repo's `latest` gives
`prod-base:latest`. If the caller passes a `container-suffix` that differs
from `<suffix>`, `setup` fails and `common` does not run.

The job conditionally executes each linter based on whether matching files
exist in the repository:

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
