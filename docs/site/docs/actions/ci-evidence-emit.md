# ci/evidence/emit

Writes a gate's `evidence.json` and uploads it, with the gate's report files,
as a `ci-evidence-<gate>` workflow-run artifact, plus a
`ci-evidence-<gate>-attempt-<n>` copy that a re-run does not replace. At release time `cd-release`
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

Consuming repositories do not add it themselves. In `ci-test` and `ci-audit`
the report files and tools come from each language's contract in
[`ci/evidence/reports`](ci-evidence-reports.md). In `ci-quality` the files are
`evidence-reports/quality-*`: the `common` and `custom` transcripts and every
lint, typecheck and build leg's reports. The tools are `vrg-validate-common`
and `vrg-validate-custom`, then the language's lint and typecheck tools, and
with BUILD on its build tools, from the same contract. Because an entry that
matches no file is skipped, `ci-quality` first checks, with that action's
`expect` mode, that every lint and typecheck report of the language, and with
BUILD on every build report, is there.

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
| `gate` | Yes | — | Evidence gate name: `security`, `test`, `audit`, `quality` or `package`. Sets the artifact names (`ci-evidence-<gate>` and `ci-evidence-<gate>-attempt-<n>`) and the `gate` field of `evidence.json`. |
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
3. **Upload the per-attempt copy.** Uploads the same directory again as
   `ci-evidence-<gate>-attempt-<n>`, where `<n>` is the run's
   `github.run_attempt`.

All attempts of a workflow run share one set of artifact names, so a re-run
that uploads `ci-evidence-<gate>` again replaces the earlier attempt's copy.
The per-attempt copy keeps each attempt's evidence, so a release can still
use an earlier attempt that passed when a later re-run failed. The harvest
still reads `ci-evidence-<gate>`. Both copies follow the repository's
artifact retention setting, and each gate now keeps two artifacts per
attempt. The evidence jobs download only the `ci-evidence-<gate>-reports-*`
and `ci-evidence-security-part-*` partials, and neither name matches those
patterns.

Because `evidence.json` is always written, the artifact is always produced,
even for a gate that has no report files yet. Whether an artifact is complete
enough is decided at release time: the harvest rejects an
`evidence.json`-only payload as incomplete (see
[All Hard Gates](../ci-gates/all-hard-gates.md#example-the-ci-evidence-gate)).

## Permissions

None beyond the default; uploading a workflow artifact needs no extra scope.
