# Security Scanning

## Overview

Three security scanning tools provide layered coverage:

| Tool | Purpose | Output |
| ------ | --------- | -------- |
| [CodeQL](../actions/ci-security-codeql.md) | GitHub-native SAST with deep semantic analysis | SARIF uploaded to code scanning |
| [Semgrep](../actions/ci-security-semgrep.md) | Fast pattern-based SAST with community rulesets | SARIF uploaded to code scanning |
| [Trivy](../actions/shared-security-trivy.md) | Dependency vulnerability scanning and SBOM generation | SARIF uploaded to code scanning |

## GHAS requirements

All three tools upload results in SARIF format to GitHub Code Scanning, which
requires **GitHub Advanced Security (GHAS)**. GHAS is available by default, at
no cost, on public repositories. Every repository is public, so GHAS is always
available.

## Accepted suppressions: uploaded SARIF vs. evidence

The SARIF gate passes a finding that has been accepted in source (for
example a justified `# nosemgrep: …`), but GitHub code scanning does not
honor SARIF `suppressions` and would still fail the scanner's SARIF analysis
check (e.g. `Semgrep OSS`) on it. To keep the two in agreement, the Semgrep
and Trivy actions run `vrg-sarif-filter` before uploading and send code
scanning a filtered copy (`*.upload.sarif`) with accepted-suppressed results
removed, using the same semantics as the gate.

The **unfiltered** SARIF (`semgrep-results.sarif`, `trivy-results.sarif`) is
what the `security / evidence` job collects into the `ci-evidence-security`
bundle, so every accepted suppression remains auditable there.

CodeQL is not filtered: `github/codeql-action/analyze` uploads its results
itself, so there is no separate upload step to hand a filtered file to.

## Check names in the PR status area

Each security scanner uploads its SARIF to code scanning, so it produces
**two** check runs on a pull request:

| CI workflow job | SARIF analysis check |
| ----------------- | ---------------------- |
| `security / codeql` | `CodeQL` |
| `security / semgrep` | `Semgrep OSS` |
| `security / trivy` | `Trivy` |

The first column shows the [ci-security](../workflows/ci-security.md) jobs,
named `<caller job> / <job>` with the standard `security` caller job key. The
second column shows the checks GitHub code scanning creates when the SARIF
results are uploaded (this needs the `security-events: write` permission).

Both columns are gated in both
[CI gates rulesets](repository-rulesets.md#ci-gates-rulesets),
`CI gates (develop)` and `CI gates (main)`:

- `security / trivy` and `security / semgrep` are always required.
- `Trivy` and `Semgrep OSS` are always required.
- `security / codeql` and `CodeQL` are required when the repository's primary
  language is supported by CodeQL.

See [Required Checks](required-checks.md) for the full required set.

## Viewing results

Security scan results appear in the repository's **Security** tab:

1. Navigate to **Security > Code scanning alerts**.
2. Filter by tool: `CodeQL`, `semgrep`, or `trivy-fs` / `trivy-image`.
3. Each alert shows the affected file, line number, severity, and a description
   of the finding.

## CodeQL

CodeQL performs deep semantic analysis of source code. It understands data flow,
control flow, and language-specific patterns.

- **Languages scanned**: Python, Go, Rust, C++ and TypeScript.
- **Query suite**: `+security-extended` (default) includes the standard security
  queries plus extended checks.
- **Autobuild**: CodeQL automatically detects the build system and compiles the
  project.

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/codeql@v2.1
  with:
    language: python
```

## Semgrep

Semgrep provides fast, pattern-based static analysis with a large library of
community-maintained rules.

Default rulesets enabled for every scan:

- `p/<language>` — Language-specific security rules
- `p/security-audit` — Cross-cutting security audit rules
- `p/secrets` — Secret detection (API keys, tokens, passwords)

Additional rulesets can be added via `extra-config`:

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/semgrep@v2.1
  with:
    language: golang
    extra-config: "p/owasp-top-ten"
```

## Trivy

Trivy scans for known vulnerabilities in dependencies and container images.

### Scan modes

| Mode | Use case | SARIF category |
| ------ | ---------- | --------------- |
| `fs` | Scan project dependencies for known CVEs | `trivy-fs` |
| `image` | Scan container images for OS and library CVEs | `trivy-image` |
| `sbom` | Generate CycloneDX SBOM (no SARIF upload) | — |

### Severity filtering

By default, only `CRITICAL` and `HIGH` severity vulnerabilities are reported.
This can be adjusted:

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: fs
    severity: "CRITICAL,HIGH,MEDIUM"
```

### Exit code behavior

By default, Trivy exits with code `1` when vulnerabilities are found, failing
the CI check. Set `exit-code: "0"` for advisory-only mode:

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: fs
    exit-code: "0"
```

## Workflow permissions

All security scanning jobs require the `security-events: write` permission:

```yaml
jobs:
  codeql:
    permissions:
      security-events: write
      contents: read
```
