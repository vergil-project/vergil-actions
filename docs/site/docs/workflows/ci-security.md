# ci-security

Standards compliance and security scanning workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Language for security scanners (e.g., `python`, `go`, `ruby`) |
| `run-standards` | boolean | no | `true` | Run the standards-compliance job |
| `run-security` | boolean | no | `true` | Run security scanner jobs (CodeQL, Semgrep, Trivy) |
| `run-codeql` | boolean | no | `true` | Run CodeQL analysis (disable for unsupported languages like `shell`) |
| `upload-sarif` | boolean | no | `true` | Upload scanner SARIF to GitHub code scanning (disable on private repos without GHAS; see below) |
| `container-suffix` | string | no | `base` | Container image name suffix for the standards job |
| `container-tag` | string | no | — | **Deprecated** — fed the removed standards job and no longer has any effect. Retained so consumers passing it do not error; slated for removal in [#876](https://github.com/vergil-project/vergil-actions/issues/876) |

## Required permissions

```yaml
permissions:
  contents: read
  security-events: write
  actions: read
```

`actions: read` is required by `codeql-action/upload-sarif` on **private**
repositories (it reads the workflow run via the Actions API). Public
repositories do not need it, but reusable-workflow jobs can only downgrade
caller permissions, so the caller must grant it for the workflow-level
grant to take effect.

### Upgrading from v2.1.2 or earlier

v2.1.3 added `actions: read` to this workflow's `permissions:` request.
GitHub validates the request against the calling job's **effective**
permissions at startup, so a caller whose `security:` job carries an
explicit `permissions:` block (the standard posture) must add
`actions: read` to that job-level block — the job block fully replaces
any workflow-level block in the caller, so a workflow-level grant alone
is not sufficient. Callers without the grant fail with `startup_failure`
and no registered checks.

The grant is backward-compatible with earlier releases, so it can merge
before the workflow pin moves to v2.1.3. See
[#698](https://github.com/vergil-project/vergil-actions/issues/698) for
the incident that motivated this note.

## Jobs and check names

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `standards` | `CI Security / standards` | `run-standards` is true |
| `codeql` | `CI Security / codeql` | `run-security`, `run-codeql`, and `upload-sarif` are true |
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
      actions: read
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
      actions: read
    with:
      language: shell
      run-codeql: false
```

## Private repos without GitHub Advanced Security

GitHub code scanning on private repositories requires GitHub Advanced
Security (GHAS). On a private repo without GHAS, set `upload-sarif: false`:

```yaml
jobs:
  security:
    uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      language: python
      upload-sarif: false
```

With `upload-sarif: false`:

- Trivy and Semgrep scans still run and still fail the job on findings;
  their SARIF results are attached to the workflow run as build artifacts
  (`trivy-fs-sarif`, `semgrep-sarif`) instead of being uploaded to code
  scanning.
- The `codeql` job is skipped entirely — CodeQL cannot run on private
  repos without GHAS, regardless of the upload destination.

The scans themselves do not require GHAS; only the code-scanning upload
destination does. Failing CI because the reporting destination is
unavailable, when the scan itself passed, is the wrong outcome — this
input degrades the destination, not the scanning.

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
