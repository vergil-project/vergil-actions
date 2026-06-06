# security/semgrep

Runs Semgrep static analysis with language-specific and cross-cutting security
rulesets.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/semgrep@v2.1
  with:
    language: python
    extra-config: "p/owasp-top-ten"
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `language` | **Yes** | — | Language ruleset to enable (maps to `p/<language>`, e.g. `python`, `java`, `golang`). |
| `extra-config` | No | `""` | Additional Semgrep config strings, space-separated (e.g. `p/owasp-top-ten`). |
| `upload-sarif` | No | `true` | Upload SARIF to GitHub code scanning. Set to `false` on private repos without GHAS; results are attached as a build artifact instead. |

## Permissions

- `security-events: write` (required for uploading SARIF results)
- `actions: read` (required by the SARIF upload on **private** repositories)
- `contents: read`

## Behavior

1. **Check language ruleset** — Queries the Semgrep registry to verify that
   `p/<language>` exists. If the registry does not have a ruleset for the
   specified language, the language-specific config is silently skipped.
2. **Auto-detect rulesets** — Scans the repository for content that benefits
   from specialized rulesets:
    - `p/dockerfile` — enabled when `Dockerfile*` files are present
    - `p/github-actions` — enabled when `.github/workflows/` contains workflow
      files
3. **Run scan** — Executes `semgrep scan` with the following config rulesets:
    - `p/ci` — CI pipeline security rules (injection, secrets in workflows,
      unsafe patterns)
    - `p/command-injection` — Unsafe shell construction and command injection
      patterns
    - `p/security-audit` — Cross-cutting security audit rules
    - `p/secrets` — Secret detection rules
    - `p/<language>` — Language-specific rules (if available in the registry)
    - `p/dockerfile` — Dockerfile best practices (if Dockerfiles detected)
    - `p/github-actions` — GitHub Actions injection patterns (if workflow files
      detected)
    - Any additional rulesets from `extra-config`
4. **Upload SARIF** — Uploads the SARIF output file to GitHub code scanning
   using `github/codeql-action/upload-sarif@v4`, categorized as `semgrep`.
   This step runs even if the scan finds issues (`if: always()`). When
   `upload-sarif` is `false`, the SARIF file is attached to the workflow run
   as a build artifact (`semgrep-sarif`) instead.

## Examples

### Python Semgrep scan

```yaml
jobs:
  semgrep:
    name: "security: semgrep"
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      contents: read
    steps:
      - uses: actions/checkout@v6
      - uses: vergil-project/vergil-actions/actions/ci/security/semgrep@v2.1
        with:
          language: python
```

### Go with additional OWASP rules

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/semgrep@v2.1
  with:
    language: golang
    extra-config: "p/owasp-top-ten"
```

## GitHub configuration

- **GitHub Advanced Security (GHAS)** — Must be enabled for SARIF upload.
  On private repos without GHAS, set `upload-sarif: false` to preserve
  results as a build artifact instead.
- **Code scanning alerts** — Results appear in the repository's **Security >
  Code scanning alerts** tab alongside CodeQL results.

## Future rulesets

Additional Semgrep rulesets (such as `p/owasp-top-ten` for web application
security) can be enabled per-repo via the `extra-config` input. These are not
included in the base config because they target specific application types that
not all repos in the fleet share.
