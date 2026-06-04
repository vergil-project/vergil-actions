# ci-test

Unit and integration test workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | yes | — | JSON array of language versions (e.g., `'["3.12", "3.13"]'`) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |

## Jobs and check names

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `unit / <version>` | `CI Test / unit / <version>` | Always runs |

## Usage

```yaml
jobs:
  test:
    uses: vergil-project/vergil-actions/.github/workflows/ci-test.yml@v2.1
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'
```

## Extension points

The `unit` job provides a version matrix scaffold. Consuming repositories
customize it by forking the workflow or by running language-specific test
commands in a separate workflow.
