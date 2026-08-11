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

## System packages

Each `unit` job installs the system packages the repository declares under
`[container].system-packages` in its `vergil.toml`, via the
[`shared/setup/system-packages`](../actions/shared-setup-system-packages.md)
action. This runs on **test jobs only** — lint and typecheck jobs do not
exercise the code and are deliberately excluded, so the packages are installed
exactly where the tests need them and nowhere else.

The install is a no-op when a repository declares no system packages. When it
does declare them, the step installs with a bounded retry (to absorb transient
apt mirror flakes) and **fails closed** if a declared package has no install
candidate — the offending package and platform are named in the log and the
test job fails rather than running against a missing dependency. See the
[action reference](../actions/shared-setup-system-packages.md) for the full
behavior, and the
[`container-config` reference](https://vergil-project.github.io/vergil-tooling/reference/container-config/)
on the vergil-tooling side for the `[container].system-packages` key itself.

## Extension points

The `unit` job provides a version matrix scaffold. Consuming repositories
customize it by forking the workflow or by running language-specific test
commands in a separate workflow.
