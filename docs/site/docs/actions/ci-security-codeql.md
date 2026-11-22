# security/codeql

Runs GitHub CodeQL static analysis (init + autobuild + analyze) for a single
language, then evaluates the resulting SARIF and fails on gating findings.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/codeql@v2.1
  with:
    language: python
    queries: "+security-extended"
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `language` | **Yes** | — | Language to analyze: `python`, `go`, `rust`, `cpp` or `typescript`. |
| `queries` | No | `+security-extended` | Query suite to run. |

## Permissions

- `security-events: write` (required for uploading SARIF results)
- `contents: read`

## Behavior

1. **Resolve the CodeQL language** — Maps the `language` input to its CodeQL
   analysis-language identifier with `resolve-language.sh`: `typescript`
   becomes `javascript-typescript` and `cpp` becomes `c-cpp`. Every other
   language passes through unchanged.
2. **Initialize CodeQL** — Uses `github/codeql-action/init@v4` to set up the
   CodeQL database for the mapped language and the query suite.
3. **Autobuild** — Uses `github/codeql-action/autobuild@v4` to automatically
   detect and build the project.
4. **Run analysis** — Uses `github/codeql-action/analyze@v4` to perform the
   analysis and upload results, writing the SARIF to
   `${{ runner.temp }}/codeql-sarif`. Results are categorized by
   `/language:<mapped language>`, for example `/language:c-cpp` for `cpp`.
5. **Fail on CodeQL findings** — Runs `vrg-sarif-evaluate` on that SARIF
   directory. It filters the findings by severity, annotates them and writes
   a job summary, and fails the step on a gating finding. `vrg-sarif-evaluate`
   comes from vergil-tooling, so install it first with
   [`shared/setup/vergil`](shared-setup-vergil.md), as `ci-security` does.

## Examples

### Python CodeQL analysis

```yaml
jobs:
  codeql:
    runs-on: ubuntu-24.04
    permissions:
      security-events: write
      contents: read
    steps:
      - uses: actions/checkout@v6
      - uses: vergil-project/vergil-actions/actions/shared/setup/vergil@v2.1
      - uses: vergil-project/vergil-actions/actions/ci/security/codeql@v2.1
        with:
          language: python
```

### Go CodeQL analysis

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/codeql@v2.1
  with:
    language: go
```

## GitHub configuration

- **GitHub Advanced Security (GHAS)** — Must be enabled on the repository for
  SARIF upload to work. For public repositories, GHAS is available by default.
- **Code scanning alerts** — Results appear in the repository's **Security >
  Code scanning alerts** tab.
