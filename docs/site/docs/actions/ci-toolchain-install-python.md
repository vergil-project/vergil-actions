# ci/toolchain/install-python

Installs a Python CI leg's dev dependencies with
`uv sync --group dev --frozen`, or skips the install with a visible notice on
a repository that is not bootstrapped yet (issue #1206).

A Python repository is bootstrapped by two manifests, `pyproject.toml` and
`uv.lock`. `vrg-validate` skips its language stages, loudly, when every one of
them is missing (vergil-tooling#4384). This action uses the same test, so a
freshly initialised Python repository reaches the leg's `vrg-validate` step and
its skip, instead of failing at the install:

| The repository has | The step |
| ------------------ | -------- |
| Neither `pyproject.toml` nor `uv.lock` | Prints a `::notice::` naming both files and passes. |
| Either of them, or both | Runs `uv sync --group dev --frozen` and fails when it fails. |

A partial bootstrap (a `pyproject.toml` with no `uv.lock`, say) is not
skipped: `uv sync --frozen` fails on it, and so does the step, as
`vrg-validate` fails it. A skipped install does not pass a repository that has
Python sources but no manifest either: the leg's `vrg-validate` fails its
install stage.

This action is **wired automatically** into every Python leg of `ci-quality`
(lint, typecheck, custom, build), `ci-audit` (dependencies) and `ci-test`
(unit), after [`ci/toolchain/pin-python`](ci-toolchain-pin-python.md).
Consuming repositories do not add it themselves.

## Usage

```yaml
- name: Pin uv to the leg's Python interpreter
  if: inputs.language == 'python'
  uses: vergil-project/vergil-actions/actions/ci/toolchain/pin-python@v2.1
  with:
    version: ${{ matrix.version }}

- name: Install dependencies
  if: inputs.language == 'python'
  uses: vergil-project/vergil-actions/actions/ci/toolchain/install-python@v2.1
```

## Inputs

None. The manifests are looked up in the working directory, the checkout.

## Behavior

On a skip, the notice reads
`skipped: no pyproject.toml, uv.lock (python repo not bootstrapped yet); add
them to install the dev dependencies`, and the step exits 0. Otherwise the
step runs `uv sync --group dev --frozen` with
`UV_PYTHON_PREFERENCE=only-system` and exits with uv's status. The interpreter
version is the one `ci/toolchain/pin-python` exported before this step.

## Implementation

The logic is in `install.sh` next to `action.yml`, so it can be unit tested
(`tests/install.test.sh`) against a fake `uv`. The same harness also checks
the CI workflows: every job that pins through `ci/toolchain/pin-python`
installs through this action after the pin, and no workflow runs `uv sync`
itself. The `smoke-setup-vergil` workflow runs the tests.

## Related

- [`ci/toolchain/pin-python`](ci-toolchain-pin-python.md) — pins uv to the
  leg's version and the image's interpreter first.
- [`ci/toolchain/assert`](ci-toolchain-assert.md) — fails the leg if it runs a
  version other than the resolved one.
