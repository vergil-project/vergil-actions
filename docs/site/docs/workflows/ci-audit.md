# ci-audit

Dependency audit workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `container-suffix` | string | no | `""` | Cross-check only. Each leg's image suffix comes from the resolver. A non-empty value must be one of the resolved suffixes (e.g. `python`, `cpp-clang`, `base`), or the `matrix` job fails. It never changes an image. |
| `container-prefix` | string | no | `prod` | Image name prefix (`prod` or `dev`) |

## Secrets

| Secret | Required | Description |
| -------- | ---------- | ------------- |
| `CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER` | no | ConanCenter provider token for `conan audit`. Only meaningful for cpp repos; other ecosystems ignore it. Pass it explicitly via the caller's `secrets:` block — never `secrets: inherit`. It is not required because non-cpp callers never use it, but a cpp caller must pass it: when it is unset, the cpp audit command fails the conan gate, and so the audit. |

## Version matrix

The matrix comes from
[`vrg-ci-resolve`](../actions/shared-setup-vergil.md) at run time: the workflow's `matrix` job
runs the shared setup action, which calls the resolver, and passes its
versions, image tags and image suffixes to
[`ci/matrix`](../actions/ci-matrix.md). Each leg pins uv to its version and to
the image's interpreter (Python, with
[`ci/toolchain/pin-python`](../actions/ci-toolchain-pin-python.md)), installs
Python's dev dependencies with
[`ci/toolchain/install-python`](../actions/ci-toolchain-install-python.md)
(skipped with a notice on a repository with neither `pyproject.toml` nor
`uv.lock`) and then asserts the running toolchain with
[`ci/toolchain/assert`](../actions/ci-toolchain-assert.md). Callers are
thin: they pass only `language:` and `container-suffix:`.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `dependencies / <version>` | `<caller> / dependencies / <version>` | Dependency audit (matrix-expanded — informational, not a required check) |
| `evidence` | `audit / evidence` | Aggregate gate — `needs` every `dependencies` leg, runs `if: always()`, and asserts each leg succeeded; a failed/skipped leg makes it **fail red** rather than skip. **This stable, version-agnostic gate is the required check** (see [Required Checks](../ci-gates/required-checks.md)) |

## Evidence reports

Each `dependencies` leg stages the language's audit reports for the
`ci-evidence-audit` artifact: `pip-audit.json` and `licenses.json` for Python,
`cargo-deny.json` for Rust, `npm-audit.json` and `licenses.json` for
TypeScript. As for Python, `licenses.json` is the license report: TypeScript's
is written by `vrg-npm-license-gate`. The names come
from [`ci/evidence/reports`](../actions/ci-evidence-reports.md). A leg whose
audit passed but wrote no report fails, unless the repository is not
bootstrapped yet and `vrg-validate` skipped the gate: the leg then prints a
notice and stages a skip record, `audit-not-bootstrapped-<version>.json`, in
place of its reports (see
[Not-bootstrapped repositories](../actions/ci-evidence-reports.md#not-bootstrapped-repositories)).
A language with no audit report contract yet (Go, C++) gets a warning and
stages nothing, and the release-time evidence gate decides.

## Usage

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: python
      container-suffix: python
```

For cpp repos, forward the ConanCenter provider token through the explicit-secret
chain so `conan audit` can authenticate:

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: cpp
      container-suffix: cpp-clang
    secrets:
      CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER: ${{ secrets.CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER }}
```

## Extension points

The `dependencies` job runs each language's real audit through
`vrg-validate --check audit`: pip-audit and pip-licenses for Python,
cargo-deny for Rust, `npm audit` and `vrg-npm-license-gate` for TypeScript.
The audit commands live in
vergil-tooling, not in this workflow. Each leg then stages its reports
through [`ci/evidence/reports`](../actions/ci-evidence-reports.md), whose
table is the one place this repository records a language's audit report
names. Giving a language without a contract yet (Go, C++) audit evidence
means adding its entry to that table alongside the vergil-tooling gate
command that writes the reports; the workflow itself needs no change.
