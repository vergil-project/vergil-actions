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
requires **GitHub Advanced Security (GHAS)**:

- **Public repositories** — GHAS is available by default at no cost.
- **Private repositories** — A GHAS license is required. Contact your GitHub
  administrator.

On a private repository **without** GHAS, set `upload-sarif: false` on the
[ci-security workflow](../workflows/ci-security.md): Trivy and Semgrep still
run (and still fail on findings) but attach their SARIF results as build
artifacts instead of uploading to code scanning, and the CodeQL job is
skipped (CodeQL cannot run on private repos without GHAS at all). See
[Private repos without GitHub Advanced Security](../workflows/ci-security.md#private-repos-without-github-advanced-security).

## Check names in the PR status area

Each security scanner produces **two** check runs on a pull request:

| CI workflow job | SARIF analysis check |
| ----------------- | ---------------------- |
| `security: codeql` | `CodeQL` |
| `security: semgrep` | `Semgrep OSS` |
| `security: trivy` | `Trivy` |

The first column shows our CI workflow jobs — these are the checks gated in the
[CI gates ruleset](repository-rulesets.md#ci-gates-ruleset). The second column
shows checks that GitHub creates automatically when SARIF results are uploaded
via the `security-events: write` permission. The SARIF analysis checks are
informational and are **not** included in the required status checks.

## Viewing results

Security scan results appear in the repository's **Security** tab:

1. Navigate to **Security > Code scanning alerts**.
2. Filter by tool: `CodeQL`, `semgrep`, or `trivy-fs` / `trivy-image`.
3. Each alert shows the affected file, line number, severity, and a description
   of the finding.

## CodeQL

CodeQL performs deep semantic analysis of source code. It understands data flow,
control flow, and language-specific patterns.

- **Languages supported**: Python, Go, Ruby, Java, JavaScript/TypeScript, and more.
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

All security scanning jobs require the `security-events: write` permission,
plus `actions: read`, which `codeql-action/upload-sarif` needs on **private**
repositories (it reads the workflow run via the Actions API):

```yaml
jobs:
  codeql:
    permissions:
      security-events: write
      actions: read
      contents: read
```
