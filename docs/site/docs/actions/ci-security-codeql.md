# security/codeql

Runs GitHub CodeQL static analysis (init + autobuild + analyze) for a single
language.

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
| `language` | **Yes** | — | CodeQL language to analyze (e.g. `python`, `javascript`, `go`, `java`). |
| `queries` | No | `+security-extended` | Query suite to run. |

## Permissions

- `security-events: write` (required for uploading SARIF results)
- `contents: read`

## Behavior

1. **Initialize CodeQL** — Uses `github/codeql-action/init@v4` to set up the
   CodeQL database for the specified language and query suite.
2. **Autobuild** — Uses `github/codeql-action/autobuild@v4` to automatically
   detect and build the project.
3. **Run analysis** — Uses `github/codeql-action/analyze@v4` to perform the
   analysis and upload results. Results are categorized by
   `/language:<language>`.

## Examples

### Python CodeQL analysis

```yaml
jobs:
  codeql:
    name: "security: codeql"
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      contents: read
    steps:
      - uses: actions/checkout@v6
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
  For private repositories, a GHAS license is required.
- **Code scanning alerts** — Results appear in the repository's **Security >
  Code scanning alerts** tab.
