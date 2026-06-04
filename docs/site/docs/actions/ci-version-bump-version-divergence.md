# release-gates/version-divergence

Verifies that the PR branch version differs from the main branch version. Fails
the step if the two versions are identical.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ci/version-bump/version-divergence@v2.1
  with:
    head-version-command: cat VERSION
    main-version-command: git show origin/main:VERSION
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `head-version-command` | **Yes** | — | Shell command that prints the HEAD (PR branch) version to stdout. |
| `main-version-command` | **Yes** | — | Shell command that prints the main branch version to stdout. |

## Outputs

| Name | Description |
| ------ | ------------- |
| `head-version` | The version extracted from the PR branch. |
| `main-version` | The version extracted from the main branch. |
| `diverged` | `true` if versions differ, `false` otherwise. |

## Permissions

- `contents: read` (default)

## Behavior

1. **Fetch main branch** — Runs `git fetch origin main --depth=1`.
2. **Compare versions** — Executes both version commands and compares the
   results. If the versions are identical, the step fails with exit code 1 and
   a diagnostic message. If they differ, the step succeeds.

## Examples

### Simple VERSION file check

```yaml
jobs:
  version-gate:
    name: "release: version-divergence"
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: vergil-project/vergil-actions/actions/ci/version-bump/version-divergence@v2.1
        with:
          head-version-command: cat VERSION
          main-version-command: git show origin/main:VERSION
```

### Python project version check

```yaml
- uses: vergil-project/vergil-actions/actions/ci/version-bump/version-divergence@v2.1
  with:
    head-version-command: >-
      grep -oP 'version\s*=\s*"\K[^"]+' pyproject.toml
    main-version-command: >-
      git show origin/main:pyproject.toml | grep -oP 'version\s*=\s*"\K[^"]+'
```

## GitHub configuration

- **Required status check** — Add this as a required status check on the
  `develop` branch to prevent PRs from merging without a version bump.
