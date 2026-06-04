# ci-audit

Dependency audit workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | yes | — | JSON array of language versions (e.g., `'["3.12", "3.13"]'`) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `dependencies / <version>` | `CI Audit / dependencies / <version>` | Dependency audit (matrix-expanded) |

## Usage

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'
```

## Extension points

The `dependencies` job provides a version matrix scaffold for running
language-specific dependency audit tools (e.g., `pip-audit`, `npm audit`,
`bundler-audit`).
