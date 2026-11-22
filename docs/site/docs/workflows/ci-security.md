# ci-security

Security scanning workflow: CodeQL, Trivy and Semgrep, plus an evidence job
that bundles their SARIF results for the release harvester.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Language for the security scanners (e.g., `python`, `go`, `rust`) |
| `run-security` | boolean | no | `true` | Run the scanner jobs (CodeQL, Trivy, Semgrep) |
| `run-codeql` | boolean | no | `true` | Run CodeQL analysis (disable for languages CodeQL does not support, such as `shell`) |
| `container-prefix` | string | no | `prod` | Image name prefix (`prod` or `dev`) for the `semgrep` job's `<prefix>-base:latest` container |
| `run-standards` | boolean | no | `false` | **Deprecated** — no longer has any effect. The standards job it controlled was removed; the input is still accepted so consumers that pass it do not error |
| `container-suffix` | string | no | — | **Deprecated** — fed the removed standards job and no longer has any effect. Still accepted so consumers that pass it do not error |

New callers should not pass `run-standards` or `container-suffix`.

## Required permissions

```yaml
permissions:
  contents: read
  security-events: write
```

GitHub validates the workflow's `permissions:` request against the calling
job's **effective** permissions at startup, so a caller whose `security:`
job carries an explicit `permissions:` block (the standard posture) must
grant both there. The job block fully replaces any workflow-level block in
the caller, so a workflow-level grant alone is not sufficient. A caller
missing a grant fails with `startup_failure` and no registered checks.

The workflow no longer requests `actions: read`, which v2.1.3 added for
SARIF uploads from private repositories (epic
[vergil-project/.github#1476](https://github.com/vergil-project/.github/issues/1476)
removed it). A caller that still grants it keeps working and can drop the
grant.

## Jobs and check names

GitHub names each check `<caller job> / <job>`. With the caller job keyed
`security` (the standard posture, as in the usage examples below):

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `codeql` | `security / codeql` | `run-security` and `run-codeql` are both true |
| `trivy` | `security / trivy` | `run-security` is true |
| `semgrep` | `security / semgrep` | `run-security` is true |
| `evidence` | `security / evidence` | `trivy` and `semgrep` succeeded, and `codeql` succeeded (`run-codeql` true) or was skipped (`run-codeql` false) |

The `evidence` job downloads each scanner's SARIF partial and emits the
consolidated `ci-evidence-security` artifact. Its `evidence.json` names the
scanners whose SARIF it holds in `tools`: `trivy` and `semgrep` always, and
`codeql` when the `codeql` job ran and passed. If any scanner fails, it does
not run, so no security evidence is emitted. It is not a required check; see
[Required Checks](../ci-gates/required-checks.md) for which of these checks
branch protection requires.

Each scanner also uploads its SARIF to code scanning, and GitHub adds its
own SARIF analysis checks (`CodeQL`, `Trivy`, `Semgrep OSS`); see
[Security Scanning](../ci-gates/security-scanning.md).

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

- The `semgrep` job runs inside the
  `ghcr.io/vergil-project/<container-prefix>-base:latest` container
  (`prod-base` by default). Semgrep never executes the target code, so it
  needs no language runtime.
- The `codeql` and `trivy` jobs run directly on `ubuntu-24.04`, with no
  container. CodeQL autobuild for compiled languages needs the language
  toolchains that the runner provides.
- Each scanner job uploads its **unfiltered** SARIF as an evidence partial,
  beside the copy sent to code scanning. For Trivy and Semgrep, the copy sent
  to code scanning omits accepted-suppressed results (via `vrg-sarif-filter`); the
  evidence copy keeps them so they remain auditable.
- The Semgrep action auto-detects repository content and enables additional
  rulesets: `p/dockerfile` when Dockerfiles are present, `p/github-actions`
  when workflow files exist under `.github/workflows/`. No configuration is
  needed from consuming repos. `vrg-semgrep-scan` resolves the language
  ruleset from the `language` input, `p/c` for `cpp` (which covers `.c` files
  only) and `p/typescript` for `typescript`.
