# ci-quality

Code quality and linting workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | no | `[ci].versions` from `vergil.toml` | JSON array of language versions (e.g., `'["3.12", "3.13"]'`). **Deprecated** — omit it; the matrix is derived from `[ci].versions` in the consumer's `vergil.toml`. Still accepted for back-compat (a supplied value is honored verbatim), slated for removal in [#876](https://github.com/vergil-project/vergil-actions/issues/876) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |
| `container-tag` | string | no | family-routed `primary-container-tag` from `[ci]` | Container image tag for the single-container `common` job. **Deprecated** — omit it; when unset the tag is derived from `[ci].primary-version` (default: the highest `[ci].versions` entry), family-routed to the published container tag. Still accepted for back-compat, slated for removal in [#876](https://github.com/vergil-project/vergil-actions/issues/876) |

## Version matrix

The `lint` and `typecheck` matrix is derived from `[ci].versions` in the
consumer's `vergil.toml` at run time — the workflow's `matrix` job runs the
shared setup action for its `versions` output whenever the caller omits the
`versions:` input. The single-container `common` job resolves its image tag from
`[ci].primary-version` (default: the highest `[ci].versions` entry) whenever the
caller omits `container-tag:`. Callers are thin: they pass only `language:` and
`container-suffix:`.

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
family-routed `primary-container-tag` derived from `[ci].primary-version`
unless the caller passes `container-tag:`. It conditionally executes each
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
