# ci-security

Security scanning workflow: CodeQL, Trivy and Semgrep, plus an evidence job
that bundles their SARIF results for the release harvester.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Language for the security scanners (e.g., `python`, `go`, `java`) |
| `run-security` | boolean | no | `true` | Run the scanner jobs (CodeQL, Trivy, Semgrep) |
| `run-codeql` | boolean | no | `true` | Run CodeQL analysis (disable for languages CodeQL does not support, such as `shell`) |
| `upload-sarif` | boolean | no | `true` | Upload scanner SARIF to GitHub code scanning (disable on private repos without GHAS; see below) |
| `container-prefix` | string | no | `prod` | Image name prefix (`prod` or `dev`) for the `semgrep` job's `<prefix>-base:latest` container |
| `run-standards` | boolean | no | `false` | **Deprecated** — no longer has any effect. The standards job it controlled was removed; the input is still accepted so consumers that pass it do not error |
| `container-suffix` | string | no | — | **Deprecated** — fed the removed standards job and no longer has any effect. Still accepted so consumers that pass it do not error |

New callers should not pass `run-standards` or `container-suffix`.

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

GitHub names each check `<caller job> / <job>`. With the caller job keyed
`security` (the standard posture, as in the usage examples below):

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `codeql` | `security / codeql` | `run-security`, `run-codeql`, and `upload-sarif` are all true |
| `trivy` | `security / trivy` | `run-security` is true |
| `semgrep` | `security / semgrep` | `run-security` is true |
| `evidence` | `security / evidence` | `trivy` and `semgrep` succeeded, and `codeql` succeeded or was skipped |

The `evidence` job downloads each scanner's SARIF partial and emits the
consolidated `ci-evidence-security` artifact. If any scanner fails, it does
not run, so no security evidence is emitted. It is not a required check; see
[Required Checks](../ci-gates/required-checks.md) for which of these checks
branch protection requires.

When SARIF is uploaded to code scanning, GitHub also adds its own SARIF
analysis checks (`CodeQL`, `Trivy`, `Semgrep OSS`); see
[Security Scanning](../ci-gates/security-scanning.md).

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

- The `semgrep` job runs inside the
  `ghcr.io/vergil-project/<container-prefix>-base:latest` container
  (`prod-base` by default). Semgrep never executes the target code, so it
  needs no language runtime.
- The `codeql` and `trivy` jobs run directly on `ubuntu-latest`, with no
  container. CodeQL autobuild for compiled languages needs the language
  toolchains that the runner provides.
- Each scanner job uploads its **unfiltered** SARIF as an evidence partial
  regardless of `upload-sarif`. For Trivy and Semgrep, the copy sent to code
  scanning omits accepted-suppressed results (via `vrg-sarif-filter`); the
  evidence copy keeps them so they remain auditable.
- The Semgrep action auto-detects repository content and enables additional
  rulesets: `p/dockerfile` when Dockerfiles are present, `p/github-actions`
  when workflow files exist under `.github/workflows/`. No configuration is
  needed from consuming repos. For `cpp` the workflow adds `p/c` (which covers
  `.c` files only), and for `typescript` it adds `p/typescript`.
