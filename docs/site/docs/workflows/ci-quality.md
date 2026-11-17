# ci-quality

Code quality, linting and custom validation workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `container-suffix` | string | no | `""` | Cross-check only. Every image suffix comes from the resolver. A non-empty value must equal the primary version's resolved suffix (e.g. `python`, `cpp-clang`, `base`), or `setup` fails. It never changes an image. |

## Version matrix

The `lint` and `typecheck` matrix comes from
[`vrg-ci-resolve`](../actions/shared-setup-vergil.md) at run time: the
workflow's `matrix` job runs the shared setup action, which calls the resolver,
and passes its versions, image tags and image suffixes to
[`ci/matrix`](../actions/ci-matrix.md). Each leg pins uv to its version and to
the image's interpreter (Python, with
[`ci/toolchain/pin-python`](../actions/ci-toolchain-pin-python.md)), installs
Python's dev dependencies with
[`ci/toolchain/install-python`](../actions/ci-toolchain-install-python.md)
(skipped with a notice on a repository with neither `pyproject.toml` nor
`uv.lock`) and then asserts the running toolchain with
[`ci/toolchain/assert`](../actions/ci-toolchain-assert.md). The
single-container `common` and `custom` jobs run on the resolver's image for
the primary version (see [Common checks](#common-checks) and
[Custom validation](#custom-validation)). Callers are thin: they pass
only `language:`, and optionally `container-suffix:` as a cross-check.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `common` | `<caller> / common` | Runs common linters based on file presence (single-container job on the primary version — informational, gated through `quality / evidence`) |
| `custom` | `<caller> / custom` | Runs the repo's custom validator with `vrg-validate --check custom`, or logs that there is none (single-container job on the primary version — informational, gated through `quality / evidence`) |
| `lint / <version>` | `<caller> / lint / <version>` | Language-specific linting (matrix-expanded — informational, not a required check) |
| `typecheck / <version>` | `<caller> / typecheck / <version>` | Language-specific type checking (matrix-expanded — informational, not a required check) |
| `build / <version>` | `<caller> / build / <version>` | The release build, `vrg-validate --check build`, once on the primary version, only for a language whose BUILD check vergil-tooling turns on (see [Release build](#release-build) — informational, gated through `quality / evidence`) |
| `evidence` | `quality / evidence` | Aggregate gate — `needs` the `common`, `custom`, `lint`, `typecheck` and `build` jobs, runs `if: always()`, and asserts each of the first four succeeded and that `build` matches the BUILD flag; a failed/skipped leg makes it **fail red** rather than skip. **This stable, version-agnostic gate is the required check** (see [Required Checks](../ci-gates/required-checks.md)) |

## Common checks

The `common` job runs inside a single container on the primary version —
`ghcr.io/vergil-project/<prefix>-<suffix>:<tag>`, the image the primary
`lint` and `typecheck` legs run on. The `setup` job resolves both parts with
the shared [setup action](../actions/shared-setup-vergil.md): `<tag>` is its
`primary-container-tag`, and `<suffix>` is the primary version's entry in its
`container-suffixes`, picked by
[shared/setup/primary-suffix](../actions/shared-setup-primary-suffix.md). For
example `clang-20` gives `prod-cpp-clang:20`, `3.14` gives
`prod-python:3.14` and a language-less repo's `latest` gives
`prod-base:latest`. If the caller passes a `container-suffix` that differs
from `<suffix>`, `setup` fails and `common` does not run.

The job conditionally executes each linter based on whether matching files
exist in the repository:

| Tool | Condition |
| ------ | ----------- |
| markdownlint | `*.md` files found |
| shellcheck | `*.sh` files or `scripts/bin/` directory found |
| yamllint | `*.yml` or `*.yaml` files found |
| hadolint | `Dockerfile*` files found |
| actionlint | `.github/workflows/` directory found |

## Custom validation

The `custom` job runs the repository's custom validator
(`scripts/bin/validate-custom` or `vrg-validate-custom`) in PR CI with
`vrg-validate --check custom`, which runs the language install stage and then
the custom stage. A repository with no custom validator gets one
"no custom validator" line and a passing job; a validator that is present but
not an executable regular file fails the job. Like `common`, it runs once, on
the same image. For Python it pins uv to the primary version's interpreter
(with [`ci/toolchain/pin-python`](../actions/ci-toolchain-pin-python.md)) and
installs the dev dependency group first (with
[`ci/toolchain/install-python`](../actions/ci-toolchain-install-python.md),
which skips it on a repository not bootstrapped yet), so the validator sees
the repo's dev dependencies; [`ci/toolchain/assert`](../actions/ci-toolchain-assert.md) then
checks the running toolchain is the primary version.

The job's transcript is uploaded as the `ci-evidence-quality-reports-custom`
partial and bundled into `ci-evidence-quality` as `quality-custom.log`. The
`evidence` job needs `custom`, so a failed or skipped custom stage fails
`quality / evidence` — there is no separate required check (epic
[vergil-project/.github#488](https://github.com/vergil-project/.github/issues/488)).

## Release build

The `build` job runs `vrg-validate --check build`, the language's build
command, the same one the release job runs, so a build that would fail at
release fails on the PR instead (epic
[vergil-project/.github#1174](https://github.com/vergil-project/.github/issues/1174)).
It runs once, on the primary version's image, with the same checkout, setup,
Python pin and `assert-toolchain` steps as a `typecheck` leg.

The job runs only when the `matrix` job's `build-enabled` output is `true`.
That output is `vrg-ci-resolve`'s `build-enabled`, passed on by the
[setup action](../actions/shared-setup-vergil.md): vergil-tooling decides
which languages have a BUILD check, and no language list lives in this
workflow, so turning BUILD on for a language needs no change here. A
vergil-tooling release older than the flag gives `false`.

A skipped `build` job is a valid result, so the `evidence` job does not
require it to succeed. It checks the result against the flag with
[`ci/evidence/assert`](../actions/ci-evidence-assert.md): skipped with
BUILD off and successful with BUILD on pass, and anything else, a skipped
build with BUILD on included, fails `quality / evidence`. The job uploads no
report. There is no separate required check and no ruleset change.

## Usage

```yaml
jobs:
  quality:
    uses: vergil-project/vergil-actions/.github/workflows/ci-quality.yml@v2.1
    with:
      language: python
      container-suffix: python
```

## Extension points

Each of the five check jobs runs a `vrg-validate` check: `common` runs
`vrg-validate --check common`, `custom` runs `vrg-validate --check custom`,
each `lint` and `typecheck` leg runs `vrg-validate --check lint` or
`vrg-validate --check typecheck` for the language, and `build` runs
`vrg-validate --check build`. The lint, typecheck and build commands live in
vergil-tooling, not in this workflow, so a language's checks change there.

## Evidence

`quality / evidence` always carries the `common` and `custom` transcripts
(`quality-common.log` and `quality-custom.log`), for every language. Each
`lint` and `typecheck` leg stages its language's reports through
[`ci/evidence/reports`](../actions/ci-evidence-reports.md), whose `lint` and
`typecheck` contracts name them, with the leg's version suffix:

| Language | Leg | Report | Tools |
| -------- | --- | ------ | ----- |
| `python` | `lint` | `quality-ruff.json` | ruff |
| `python` | `typecheck` | `quality-mypy.xml` | mypy |
| `rust` | `lint` | `quality-clippy.json` | rustfmt, clippy |
| `rust` | `typecheck` | `quality-cargo-check.json` | cargo |
| `typescript` | `lint` | `quality-eslint.json` | prettier, eslint |
| `typescript` | `typecheck` | `quality-tsc.txt` | tsc |

The reports are required. A leg that passes but leaves its report missing
or empty fails its staging step. A leg that fails is not failed again for a
missing report. Before it emits, the `evidence` job checks that every report
of the language is there from at least one leg, and fails naming any that is
not. The emitted artifact takes every `quality-*` file the jobs uploaded,
and its tools are `vrg-validate-common`, `vrg-validate-custom`, then the
language's lint and typecheck tools.

A fleet language with no lint or typecheck contract yet (`go`, `cpp`) gets
a warning on its legs and in the `evidence` job, stages no report and lists
no lint or typecheck tools. A repository with no fleet
primary language (a shell or Claude plugin repository, or one that passes no
`language`) gets a notice instead. Either way the evidence carries the
`common` and `custom` transcripts and their tools only.
