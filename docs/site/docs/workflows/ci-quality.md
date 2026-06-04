# ci-quality

Code quality and linting workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | yes | — | JSON array of language versions (e.g., `'["3.12", "3.13"]'`) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |
| `container-tag` | string | no | `latest` | Container image tag for non-matrix jobs |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `common` | `CI Quality / common` | Runs common linters based on file presence |
| `lint / <version>` | `CI Quality / lint / <version>` | Language-specific linting (matrix-expanded) |
| `typecheck / <version>` | `CI Quality / typecheck / <version>` | Language-specific type checking (matrix-expanded) |

## Common checks

The `common` job runs inside the `ghcr.io/vergil-project/dev-base:latest`
container and conditionally executes each linter based on whether matching
files exist in the repository:

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
      versions: '["3.12", "3.13", "3.14"]'
```

## Extension points

The `lint` and `typecheck` jobs provide a version matrix scaffold. Consuming
repositories customize these jobs by forking the workflow or by running
language-specific tooling in a separate workflow that calls these as a
baseline.
