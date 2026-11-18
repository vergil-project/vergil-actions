# ci/toolchain/assert

Fails a CI leg when the interpreter or toolchain actually running it is not the
version CI resolved for it. A repository's own files can choose the interpreter
behind Vergil's back (for Python, `.python-version` or uv's
`python-preference`; for Rust, a `rust-toolchain.toml` or a rustup override),
and a leg would then pass on a version it never ran. This action is the
backstop for that. For Rust, the image already pins rustup to its own release
(`RUSTUP_TOOLCHAIN`, with auto-install off) and `vrg-validate` rejects a
`rust-toolchain.toml`, so the assertion is the last check behind those. For
TypeScript, Vergil selects the Node runtime, and the assertion checks that the
Node on the job's `PATH` is the leg's major.

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
| `expected` | Yes | — | The version CI resolved for this leg, as `x.y` (e.g. `3.14`, `1.26`, `1.100`), or for `typescript` a Node major, bare or with a leading `node-` (e.g. `node-26`, `26`). Ignored for languages without an assertion. |

## Behavior

| Language | Check |
| -------- | ----- |
| `python` | Runs `uv run --frozen python -c '...'` and compares the interpreter's `x.y` with `expected`, logging the interpreter's path. `--frozen` keeps uv from rewriting `uv.lock`. |
| `go` | Runs `go env GOVERSION` in the module (so a `toolchain` switch in `go.mod` is what gets reported) and compares its `x.y` (`go1.26.3` is `1.26`). |
| `rust` | Runs `rustc --version` in the repository checkout (so a rustup override would be what gets reported) and compares its `x.y` (`rustc 1.100.0` is `1.100`). |
| `typescript` | Runs `node -p 'process.versions.node + "\n" + process.execPath'` once, in the repository checkout, and compares the version's major (`26.1.0` is `26`) with `expected` (a leading `node-` stripped), logging the Node executable's path. |
| Any other | No check yet; prints a `::notice::` saying so and passes. |

On a mismatch the step fails with
`::error::CI resolved <expected> but the job runs <actual>`. It also fails,
with an `::error::` annotation, when `expected` is not an `x.y` version (for
`typescript`, not a Node major), or the toolchain cannot be asked for its
version or gives an answer it cannot read.

## Implementation

The logic is in `assert.sh` next to `action.yml`, so it can be unit tested
(`tests/assert.test.sh`, which fakes `uv`, `go`, `rustc` and `node`). The
`smoke-setup-vergil` workflow runs the tests.

## Related

- [`shared/setup/vergil`](shared-setup-vergil.md) — resolves the versions the
  legs run.
- [`ci/matrix`](ci-matrix.md) — builds the legs from those versions.
