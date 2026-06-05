# ci-version-bump

Version divergence gate workflow.

The gate follows the consuming repo's configuration: the job reads
`release-model` from `vergil.toml` and, when it is `"none"`, passes
without running the gate. Non-releasing repos need no caller wiring to
stay green.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `run-release` | boolean | no | `true` | **Deprecated** — the gate follows `release-model` in `vergil.toml`. Passing `false` still suppresses the gate but emits a deprecation warning. Tracked for removal in [#688](https://github.com/vergil-project/vergil-actions/issues/688) |
| `container-suffix` | string | no | `base` | Container image name suffix (e.g. `python`, `base`) |
| `container-tag` | string | no | `latest` | Container image tag (e.g. `3.14`, `1.26`) |

## Jobs and check names

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `version-bump` | `CI Version Bump / version-bump` | Always runs; the gate steps run only when `release-model` is not `none` |

## Usage

```yaml
jobs:
  version:
    uses: vergil-project/vergil-actions/.github/workflows/ci-version-bump.yml@v2.1
    with:
      language: python
```

Repos that don't release (e.g., infrastructure or documentation repos)
declare it in `vergil.toml` instead of passing `run-release: false`:

```toml
[project]
release-model = "none"
```

The version-bump job then passes without running the gate, and the
tooling-derived required-check set omits it entirely.
