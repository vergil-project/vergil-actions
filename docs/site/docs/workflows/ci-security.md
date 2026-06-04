# ci-security

Standards compliance and security scanning workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Language for security scanners (e.g., `python`, `go`, `ruby`) |
| `run-standards` | boolean | no | `true` | Run the standards-compliance job |
| `run-security` | boolean | no | `true` | Run security scanner jobs (CodeQL, Semgrep, Trivy) |
| `run-codeql` | boolean | no | `true` | Run CodeQL analysis (disable for unsupported languages like `shell`) |
| `container-suffix` | string | no | `base` | Container image name suffix for the standards job |
| `container-tag` | string | no | `latest` | Container image tag for the standards job |

## Required permissions

```yaml
permissions:
  contents: read
  security-events: write
```

## Jobs and check names

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `standards` | `CI Security / standards` | `run-standards` is true |
| `codeql` | `CI Security / codeql` | `run-security` and `run-codeql` are true |
| `trivy` | `CI Security / trivy` | `run-security` is true |
| `semgrep` | `CI Security / semgrep` | `run-security` is true |

## Usage

```yaml
jobs:
  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
    with:
      language: python
```

To skip CodeQL for languages it does not support:

```yaml
jobs:
  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
    with:
      language: shell
      run-codeql: false
```

## Implementation notes

- The `standards` and `semgrep` jobs run inside the
  `ghcr.io/vergil-project/dev-base:latest` container.
- The `standards` job installs `vergil-tooling` from the version pinned in
  `vergil.toml`.
- For Python repositories, the `standards` job runs `uv sync --group dev --frozen`
  to make project-installed tools available on `PATH`.
- The Semgrep action auto-detects repository content and enables additional
  rulesets: `p/dockerfile` when Dockerfiles are present, `p/github-actions`
  when workflow files exist under `.github/workflows/`. No configuration is
  needed from consuming repos.
