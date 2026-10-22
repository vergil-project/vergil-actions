# ci/toolchain/assert

Fails a CI leg when the interpreter or toolchain actually running it is not the
version CI resolved for it. A repository's own files can choose the interpreter
behind Vergil's back (for Python, `.python-version` or uv's
`python-preference`), and a leg would then pass on a version it never ran. This
action is the backstop for that.

This action is **wired automatically** into every matrix leg of `ci-quality`,
`ci-audit` and `ci-test`, as the `assert-toolchain` step. It runs after the
dependency install. For Python, an earlier step in the leg
([`ci/toolchain/pin-python`](ci-toolchain-pin-python.md)) sets `UV_PYTHON` to
the leg's version and `UV_PYTHON_PREFERENCE` to `only-system`, so uv uses the
image's interpreter for the install and the checks. Consuming repositories do
not add it themselves.

## Usage

```yaml
- name: assert-toolchain
  uses: vergil-project/vergil-actions/actions/ci/toolchain/assert@v2.1
  with:
    language: python
    expected: ${{ matrix.version }}
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `language` | Yes | — | Primary language of the calling repository. |
| `expected` | Yes | — | The version CI resolved for this leg, as `x.y` (e.g. `3.14`, `1.26`). Ignored for languages without an assertion. |

## Behavior

| Language | Check |
| -------- | ----- |
| `python` | Runs `uv run --frozen python -c '...'` and compares the interpreter's `x.y` with `expected`, logging the interpreter's path. `--frozen` keeps uv from rewriting `uv.lock`. |
| `go` | Runs `go env GOVERSION` in the module (so a `toolchain` switch in `go.mod` is what gets reported) and compares its `x.y` (`go1.26.3` is `1.26`). |
| Any other | No check yet; prints a `::notice::` saying so and passes. |

On a mismatch the step fails with
`::error::CI resolved <expected> but the job runs <actual>`. It also fails,
with an `::error::` annotation, when `expected` is not an `x.y` version or the
toolchain cannot be asked for its version.

## Implementation

The logic is in `assert.sh` next to `action.yml`, so it can be unit tested
(`tests/assert.test.sh`, which fakes `uv` and `go`). The
`smoke-setup-vergil` workflow runs the tests.

## Related

- [`shared/setup/vergil`](shared-setup-vergil.md) — resolves the versions the
  legs run.
- [`ci/matrix`](ci-matrix.md) — builds the legs from those versions.
