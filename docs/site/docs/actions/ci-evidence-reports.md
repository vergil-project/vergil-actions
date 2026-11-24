# ci/evidence/reports

Holds the per-language report-file contract of the `test` and `audit` evidence
gates and of the `quality` gate's `lint` and `typecheck` legs, stages one
matrix leg's reports for the gate's evidence artifact, and checks that the
quality evidence job received every lint and typecheck report.

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
| `python` | `lint` | `quality-ruff.json` | ruff |
| `python` | `typecheck` | `quality-mypy.xml` | mypy |
| `rust` | `lint` | `quality-clippy.json` | rustfmt, clippy |
| `rust` | `typecheck` | `quality-cargo-check.json` | cargo |
| `typescript` | `test` | `coverage.xml`, `junit.xml` | vitest, @vitest/coverage-v8 |
| `typescript` | `audit` | `npm-audit.json`, `licenses.json` | npm audit, vrg-npm-license-gate |
| `typescript` | `lint` | `quality-eslint.json` | prettier, eslint |
| `typescript` | `typecheck` | `quality-tsc.txt` | tsc |

`lint` and `typecheck` are the legs of the `quality` gate in
[`ci-quality`](../workflows/ci-quality.md). Each leg is its own job and
writes only its own report, so the contract is per leg. The gate's `common`
and `custom` transcripts (`quality-common.log` and `quality-custom.log`)
belong to no leg's contract; `ci-quality` stages them itself.

The Rust test gate writes `junit.xml` through cargo-nextest, and the Rust
lint and typecheck gates write `quality-clippy.json` and
`quality-cargo-check.json` (clippy's and `cargo check`'s
`--message-format=json` output) from
[vergil-tooling#4473](https://github.com/vergil-project/vergil-tooling/issues/4473)
on. A repository pinned to a vergil-tooling release whose Rust gate does not
write its report fails its passing legs here, on the missing file.
`cargo-deny.json`, `quality-clippy.json` and `quality-cargo-check.json` hold
JSON Lines, one object per line; they are staged as written.

The TypeScript gates write their reports from
[vergil-tooling#4508](https://github.com/vergil-project/vergil-tooling/issues/4508)
on: Vitest's JUnit report and its Cobertura coverage (copied to
`coverage.xml`), `npm audit --json` as `npm-audit.json`, ESLint's JSON
formatter output as `quality-eslint.json`, and the `tsc --diagnostics`
output as `quality-tsc.txt`. Prettier runs first in the `lint` gate and
writes no report. As for Rust, a repository pinned to a vergil-tooling
release without them fails its passing legs here.

Like Python's, the TypeScript `audit` gate also writes a license report,
`licenses.json`: `vrg-npm-license-gate` checks each package in the committed
`package-lock.json` against the license policy and writes its findings there,
from
[vergil-tooling#4722](https://github.com/vergil-project/vergil-tooling/issues/4722)
on (released in vergil-tooling v2.1.327). A repository pinned to an earlier
vergil-tooling release fails its passing TypeScript `audit` legs here, on the
missing `licenses.json`.

This table, in `actions/ci/evidence/reports/reports.sh`, is the one place
vergil-actions records the contract. The files are written by vergil-tooling's
gate commands (`lib/languages.py`), so a change to a gate's report names
changes both.

A fleet language with no entry in the table (today `go` and `cpp`) writes
no report file the release-time evidence gate accepts yet. Its legs do not fail: the step emits a `::warning::` naming the language
and gate and saying its reports are not produced yet, and stages nothing, and
`mode: tools` gives an empty tools list with the same warning. The
release-time evidence gate still decides; in enforcing mode it rejects an
empty payload.

The `quality` gate also serves repositories with no fleet primary language:
a shell or Claude plugin repository, or one that passes no `language`. Their
`lint` and `typecheck` legs write no report, so for those two gates such a
language, or an empty one, is not an error: the step emits a `::notice::`
saying it has no report contract, stages nothing and lists no tools, and the
quality evidence carries the `common` and `custom` transcripts alone. The
`test` and `audit` gates still refuse it.

Any other unknown language, an unknown gate, an empty or unsafe `version`,
or an unknown `mode` fails the step.

This action is **wired automatically** into `ci-test`, `ci-audit` and
`ci-quality`. Consuming repositories do not add it themselves.

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
    reports-dir: evidence-reports

- uses: vergil-project/vergil-actions/actions/ci/evidence/emit@v2.1
  with:
    gate: test
    files: evidence-reports/*
    tools: ${{ steps.reports.outputs.tools }}
```

The `quality` evidence job checks the downloaded legs with `mode: expect`
before it emits, since the emit action skips a pattern that matches nothing:

```yaml
- name: Require the lint and typecheck reports
  uses: vergil-project/vergil-actions/actions/ci/evidence/reports@v2.1
  with:
    mode: expect
    language: rust
    reports-dir: evidence-reports
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `mode` | Yes | — | `stage` copies this leg's reports into `out-dir`; `tools` outputs the gate's tools JSON; `expect` checks `reports-dir` holds every lint and typecheck report of the language. |
| `language` | Yes | — | Primary language of the calling repository, e.g. `python` or `rust`. May be empty only for the `lint` and `typecheck` gates and in `expect` mode. |
| `gate` | Stage and tools modes | `""` | `test`, `audit`, `lint` or `typecheck`. Not used in `expect` mode. |
| `version` | Stage mode | `""` | The matrix leg's version label, appended to each staged file's stem. |
| `gate-outcome` | Stage mode | `""` | The outcome of the step that ran the gate (`steps.<id>.outcome`). |
| `out-dir` | No | `ci-reports` | Stage mode, the directory to stage the reports into. |
| `reports-dir` | Expect mode; optional in tools mode | `""` | The directory holding every leg's staged reports, the evidence job's download directory. In tools mode, a gate whose legs left skip records there lists no tools. |

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
- A gate skipped because the repository is not bootstrapped yet is accepted,
  as [Not-bootstrapped repositories](#not-bootstrapped-repositories) says.
- For a language with no entry in the table, the step warns (or, for a
  `lint` or `typecheck` leg of a repository with no fleet primary language,
  notes) and stages nothing, whatever `gate-outcome` says.

**Tools.** Writes the gate's tools JSON array to the `tools` output: `[]`,
with a warning or notice, for a language with no entry. Given `reports-dir`,
a gate whose legs were skipped as not bootstrapped lists no tools (see below).

**Expect.** For each of the language's `lint` and `typecheck` reports,
`reports-dir` must hold at least one non-empty, version-suffixed copy
(`<stem>-<version>.<ext>`, for example `quality-clippy-1.95.json`). A missing
one fails the step with an `::error::` naming it. For a language with no
lint or typecheck entry, the step warns or notes as above and passes. A gate
whose legs were all skipped as not bootstrapped needs no report (see below).
An empty `reports-dir`, or one that is not a directory, fails.

## Not-bootstrapped repositories

A freshly initialised repository has none of its language's manifests yet
(no `pyproject.toml` or `uv.lock`, no `Cargo.toml` or `Cargo.lock`, no
`package.json` or `package-lock.json`, or a `package.json` that declares no
dependency and no `package-lock.json`) and no source of the language.
`vrg-validate` skips its language stages for such a repository, loudly,
recording each one `warn` in `.vergil/vrg-validate-last.json`
([vergil-tooling#4384](https://github.com/vergil-project/vergil-tooling/issues/4384)),
and the gate passes having written no report.

In `stage` mode a leg whose gate passed and wrote none of its reports is
accepted as skipped only when all of these hold:

- the `vrg-validate` record is of the checked-out commit and the run exited 0;
- every stage the run recorded is `warn`, the gate's own among them, so no
  stage really ran;
- every manifest of the language is missing, by the same strict test as
  `vrg-validate`, repeated here; a partial bootstrap is not a skip;
- the repository has no source of the language.

The step then prints a `::notice::` naming the leg and the reason, stages no
report, and writes the leg's **skip record** into `out-dir`:
`<gate>-not-bootstrapped-<version>.json`, or
`quality-<gate>-not-bootstrapped-<version>.json` for a `lint` or `typecheck`
leg. It is a JSON object with `"skipped": true`, `"reason":
"not-bootstrapped"`, the gate, language, version, the commit (`head`) and the
missing manifests. When any condition fails, each failing one is an
`::error::` and the leg fails on its missing reports, as any passing gate that
wrote no report does.

In `expect` mode a `lint` or `typecheck` gate with no report passes, with a
`::notice::`, when `reports-dir` holds its legs' skip records. A skip record
of another language or gate, or one found beside a report of the same gate,
fails the step.

In `tools` mode, given `reports-dir`, the step reads the same skip records
the same way. A gate whose legs left them gives `[]`, with a `::notice::`
naming them, so the gate's `evidence.json` names no tool that never ran; a
skip record `expect` mode would refuse fails the step here too. `ci-test`,
`ci-audit` and `ci-quality` pass their download directory.

The skip record is uploaded with the leg's reports and reaches the gate's
evidence artifact, so the release-time evidence gate finds the skip recorded
in the gate's payload rather than an empty one. A bootstrapped repository
never gets a skip record, so a missing report there still fails the leg.
