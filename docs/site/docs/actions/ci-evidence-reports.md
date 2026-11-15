# ci/evidence/reports

Holds the per-language report-file contract of the `test` and `audit` evidence
gates, and stages one matrix leg's reports for the gate's evidence artifact.

`vrg-validate` writes each gate's machine-readable reports at the workspace
root. At release time the evidence gate
([`cd/release/ci-evidence-gate`](cd-release-ci-evidence-gate.md)) refuses a
required gate whose artifact carries no report file, so the names staged here
must be the ones the language's gate commands write:

| Language | Gate | Report files | Tools |
| -------- | ---- | ------------ | ----- |
| `python` | `test` | `coverage.xml`, `junit.xml` | pytest, coverage.py |
| `python` | `audit` | `pip-audit.json`, `licenses.json` | pip-audit, pip-licenses |
| `rust` | `test` | `coverage.xml`, `junit.xml` | cargo-llvm-cov, cargo-nextest |
| `rust` | `audit` | `cargo-deny.json` | cargo-deny |

The Rust test gate writes `junit.xml` through cargo-nextest. A repository
pinned to a vergil-tooling release whose Rust test gate does not write it
fails its passing test legs here, on the missing `junit.xml`.
`cargo-deny.json` holds JSON Lines, one object per line; it is staged as
written.

This table, in `actions/ci/evidence/reports/reports.sh`, is the one place
vergil-actions records the contract. The files are written by vergil-tooling's
gate commands (`lib/languages.py`), so a change to a gate's report names
changes both.

A fleet language with no entry in the table (today `go`, `cpp` and
`typescript`) writes no report file the release-time evidence gate accepts
yet. Its legs do not fail: the step emits a `::warning::` naming the language
and gate and saying its reports are not produced yet, and stages nothing, and
`mode: tools` gives an empty tools list with the same warning. The
release-time evidence gate still decides; in enforcing mode it rejects the
empty payload. An unknown language or gate, an empty or unsafe `version`, or
an unknown `mode` fails the step.

This action is **wired automatically** into `ci-test` and `ci-audit`.
Consuming repositories do not add it themselves.

## Usage

```yaml
- name: Run unit tests
  id: gate
  run: vrg-validate --check test

- name: Stage test reports for evidence
  if: always()
  uses: vergil-project/vergil-actions/actions/ci/evidence/reports@v2.1
  with:
    mode: stage
    language: rust
    gate: test
    version: ${{ matrix.version }}
    gate-outcome: ${{ steps.gate.outcome }}
```

In the evidence job, `mode: tools` gives the tools JSON for
[`ci/evidence/emit`](ci-evidence-emit.md):

```yaml
- name: Resolve test evidence tools
  id: reports
  uses: vergil-project/vergil-actions/actions/ci/evidence/reports@v2.1
  with:
    mode: tools
    language: rust
    gate: test

- uses: vergil-project/vergil-actions/actions/ci/evidence/emit@v2.1
  with:
    gate: test
    files: evidence-reports/*
    tools: ${{ steps.reports.outputs.tools }}
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `mode` | Yes | — | `stage` copies this leg's reports into `out-dir`; `tools` outputs the gate's tools JSON. |
| `language` | Yes | — | Primary language of the calling repository, e.g. `python` or `rust`. |
| `gate` | Yes | — | `test` or `audit`. |
| `version` | Stage mode | `""` | The matrix leg's version label, appended to each staged file's stem. |
| `gate-outcome` | Stage mode | `""` | The outcome of the step that ran the gate (`steps.<id>.outcome`). |
| `out-dir` | No | `ci-reports` | Stage mode, the directory to stage the reports into. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `tools` | Tools mode, the gate's tools JSON array, e.g. `[{"name":"cargo-deny"}]`. |

## Behavior

**Stage.** Each of the language's report files is copied into `out-dir` as
`<stem>-<version>.<ext>`, for example `cargo-deny.json` as
`cargo-deny-1.85.json`, so every version's report stays distinct once the
evidence job flattens the legs' files by basename. No other file is staged,
so the evidence job takes every file the legs uploaded.

- When `gate-outcome` is `success`, every report must exist and be non-empty.
  A missing or empty one fails the step with an `::error::` naming it, so a
  gate that passed without writing its evidence fails the leg, and through it
  the required `evidence` check, instead of failing later at release.
- When the gate step did not succeed, the leg has already failed. The reports
  that exist are staged for diagnosis and the missing ones are noted.
- An empty or placeholder file is never staged.
- For a language with no entry in the table, the step warns and stages
  nothing, whatever `gate-outcome` says.

**Tools.** Writes the gate's tools JSON array to the `tools` output: `[]`,
with a warning, for a language with no entry.
