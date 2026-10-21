# ci/evidence/emit

Writes a gate's `evidence.json` and uploads it, with the gate's report files,
as a `ci-evidence-<gate>` workflow-run artifact. At release time `cd-release`
harvests these artifacts (`vrg-ci-evidence`) into the attested evidence bundle
it attaches to the GitHub Release (see
[`cd/release/ci-evidence-gate`](cd-release-ci-evidence-gate.md) and
[`cd/release/ci-evidence-attach`](cd-release-ci-evidence-attach.md)).

This action is **wired automatically** into the evidence-producing jobs of the
reusable CI workflows:

| Workflow | `gate` |
| -------- | ------ |
| `ci-security` | `security` |
| `ci-quality` | `quality` |
| `ci-audit` | `audit` |
| `ci-test` | `test` |
| `ci-package` | `package` |

Consuming repositories do not add it themselves.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ci/evidence/emit@v2.1
  with:
    gate: test
    files: |
      evidence-reports/coverage-*.xml
      evidence-reports/junit-*.xml
    tools: '[{"name": "pytest"}, {"name": "coverage.py"}]'
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `gate` | Yes | — | Evidence gate name: `security`, `test`, `audit`, `quality` or `package`. Sets the artifact name (`ci-evidence-<gate>`) and the `gate` field of `evidence.json`. |
| `files` | No | `""` | Newline- or space-separated report file paths or globs to include (e.g. SARIF, coverage XML, JUnit XML). An entry that matches no file is skipped, not an error. |
| `tools` | No | `[]` | JSON array for the `tools` field, e.g. `[{"name":"codeql","version":"2.17.0"}]`. |
| `metrics` | No | `{}` | JSON object for the `metrics` field, e.g. coverage percent or finding counts. |

The action has no outputs.

## Behavior

1. **Stage.** Creates `$RUNNER_TEMP/ci-evidence-<gate>`, copies every regular
   file that matches an entry in `files` into it (flattened to its basename),
   and writes `evidence.json`:

    ```json
    {"gate": "<gate>", "tools": [...], "metrics": {...}, "files": ["<basename>", ...]}
    ```

    `tools` and `metrics` must be valid JSON; `jq` fails the step otherwise.
2. **Upload.** Uploads the staging directory as the `ci-evidence-<gate>`
   artifact with `actions/upload-artifact`.

Because `evidence.json` is always written, the artifact is always produced,
even for a gate that has no report files yet. Whether an artifact is complete
enough is decided at release time: the harvest rejects an
`evidence.json`-only payload as incomplete (see
[All Hard Gates](../ci-gates/all-hard-gates.md#example-the-ci-evidence-gate)).

## Permissions

None beyond the default; uploading a workflow artifact needs no extra scope.
