# security/trivy

Runs Trivy vulnerability scanning, SBOM generation, or container image scanning.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: fs
    scan-ref: "."
    severity: "CRITICAL,HIGH"
    exit-code: "1"
    scanners: "vuln"
    output-file: "trivy-results.sarif"
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `scan-type` | **Yes** | — | Scan mode: `fs` (filesystem vuln scan to SARIF), `sbom` (CycloneDX SBOM generation), or `image` (container image scan to SARIF). |
| `scan-ref` | No | `.` | Filesystem path or container image reference to scan. |
| `severity` | No | `CRITICAL,HIGH` | Comma-separated severity levels to report. |
| `exit-code` | No | `1` | Exit code when vulnerabilities are found (`0` = advisory only). |
| `scanners` | No | `vuln` | Comma-separated Trivy scanners to enable. |
| `output-file` | No | `trivy-results.sarif` | Output file path for SARIF or SBOM results. |
| `sarif-category` | No | `""` | Category for SARIF upload. Use unique values when multiple matrix entries upload SARIF to avoid overwrites. Defaults to `trivy-fs` or `trivy-image` based on scan-type. |
| `trivyignores` | No | `""` | Comma-separated list of `.trivyignore` file paths. |
| `trivy-image` | No | `aquasec/trivy:0.70.0` | Docker image to use for Trivy. Override to pin a specific version. |
| `upload-sarif` | No | `true` | Upload SARIF to GitHub code scanning. Set to `false` on private repos without GHAS; results are attached as a build artifact instead. |

## Permissions

- `security-events: write` (required for SARIF upload when `scan-type` is `fs`
  or `image`)
- `actions: read` (required by the SARIF upload on **private** repositories)
- `contents: read`

## Behavior

The action runs Trivy via Docker (`docker run`) rather than the
`aquasecurity/trivy-action` GitHub Action. Each scan mode uses a single Docker
session that scans once to JSON, then converts to both table output (stdout) and
SARIF (file). The `trivy convert` step operates on cached JSON with no re-scan
or extra DB download.

The `fs` and `image` vuln scans skip pip's vendored CycloneDX SBOM
(`**/pip/_vendor/bom.cdx.json`, shipped by pip 26.x). Trivy would otherwise
ingest that SBOM and report pip's **vendored** dependencies (e.g. `setuptools`,
`msgpack`) as findings even though they are pip internals, not the scan target's
attack surface. The `sbom` mode does **not** skip it — an SBOM should describe
everything present.

### Filesystem scan (`fs`)

1. Runs `trivy fs` inside the Trivy Docker container against the specified
   `scan-ref`.
2. Outputs results as a table to stdout and in SARIF format to the output file.
3. Uploads the SARIF file to GitHub code scanning (category: `trivy-fs` or
   custom `sarif-category`).

### Image scan (`image`)

1. Runs `trivy image` inside the Trivy Docker container against the specified
   image reference (with Docker socket mounted).
2. Outputs results as a table to stdout and in SARIF format to the output file.
3. Uploads the SARIF file to GitHub code scanning (category: `trivy-image` or
   custom `sarif-category`).

### SBOM generation (`sbom`)

1. Runs `trivy fs` with `--format cyclonedx` inside the Trivy Docker container.
2. Outputs the SBOM to the specified output file. No SARIF upload.

## Examples

### Filesystem vulnerability scan

```yaml
jobs:
  trivy:
    name: "security: trivy"
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      contents: read
    steps:
      - uses: actions/checkout@v6
      - uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
        with:
          scan-type: fs
```

### Container image scan

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: image
    scan-ref: "myapp:latest"
```

### SBOM generation (advisory only)

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: sbom
    output-file: sbom.cdx.json
```

### Custom SARIF category for matrix builds

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: fs
    sarif-category: "trivy-fs-${{ matrix.target }}"
```

### Private repo without GHAS (artifact fallback)

```yaml
- uses: vergil-project/vergil-actions/actions/shared/security/trivy@v2.1
  with:
    scan-type: fs
    upload-sarif: false
```

The scan still runs and still fails on findings; the SARIF file is attached
to the workflow run as a build artifact (named after the SARIF category,
e.g. `trivy-fs-sarif`) instead of being uploaded to code scanning.

## GitHub configuration

- **GitHub Advanced Security (GHAS)** — Must be enabled for SARIF upload
  (`fs` and `image` scan types). On private repos without GHAS, set
  `upload-sarif: false` to preserve results as a build artifact instead.
- **Code scanning alerts** — Results appear in **Security > Code scanning
  alerts** with categories `trivy-fs` or `trivy-image`.
