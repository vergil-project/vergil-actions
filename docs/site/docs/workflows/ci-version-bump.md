# ci-version-bump

Version divergence gate workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `run-release` | boolean | no | `true` | Run the version-bump verification job |
| `container-suffix` | string | no | `base` | Container image name suffix (e.g. `python`, `base`) |
| `container-tag` | string | no | `latest` | Container image tag (e.g. `3.14`, `1.26`) |

## Jobs and check names

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `version-bump` | `CI Version Bump / version-bump` | `run-release` is true |

## Usage

```yaml
jobs:
  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.1
    with:
      language: python
```

To skip version gates (e.g., for infrastructure repos that don't version):

```yaml
jobs:
  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.1
    with:
      language: shell
      run-release: false
```
