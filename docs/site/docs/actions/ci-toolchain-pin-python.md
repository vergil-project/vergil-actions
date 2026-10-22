# ci/toolchain/pin-python

Pins uv to a CI leg's Python interpreter. It exports two variables to the rest
of the job:

| Variable | Value | What it fixes |
| -------- | ----- | ------------- |
| `UV_PYTHON` | The leg's resolved `x.y` | The **version**: the one CI resolved, not one a repository file such as `.python-version` selects. |
| `UV_PYTHON_PREFERENCE` | `only-system` | The **source**: the image's interpreter. |

A repository may set uv's `python-preference` (for example `only-managed`, so a
local VM never seeds a venv from the host interpreter). That setting picks
managed versus system Python, not the version. Without the second variable, a
leg in such a repository would have uv download its own managed Python and
pass on an interpreter the image never provided. With it, uv always uses the
image's interpreter, and a missing interpreter fails the leg instead of being
downloaded (epic vergil-project/.github#407, spec §6.5). uv's environment
variables take precedence over a repository's uv settings.

This action is **wired automatically** into every Python matrix leg of
`ci-quality` (lint, typecheck), `ci-audit` (dependencies) and `ci-test`
(unit), before the dependency install. Consuming repositories do not add it
themselves. [`ci/toolchain/assert`](ci-toolchain-assert.md) is the backstop that
checks the result.

## Usage

```yaml
- name: Pin uv to the leg's Python interpreter
  if: inputs.language == 'python'
  uses: vergil-project/vergil-actions/actions/ci/toolchain/pin-python@v2.1
  with:
    version: ${{ matrix.version }}
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `version` | Yes | — | The Python version CI resolved for this leg, as `x.y` (e.g. `3.14`). |

## Behavior

Appends `UV_PYTHON=<version>` and `UV_PYTHON_PREFERENCE=only-system` to
`$GITHUB_ENV`. The step fails with an `::error::` annotation, writing nothing,
when `version` is not an `x.y` version or `GITHUB_ENV` is not set.

## Implementation

The logic is in `pin.sh` next to `action.yml`, so it can be unit tested
(`tests/pin.test.sh`). The same harness also checks the CI workflows: every job
with an `assert-toolchain` step must pin through this action, and no workflow
may set `UV_PYTHON` by hand. The `smoke-setup-vergil` workflow runs the tests.

## Related

- [`ci/toolchain/assert`](ci-toolchain-assert.md) — fails the leg if it runs a
  version other than the resolved one.
- [`ci/matrix`](ci-matrix.md) — builds the legs and their versions.
