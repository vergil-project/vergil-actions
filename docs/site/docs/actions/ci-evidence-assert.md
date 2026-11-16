# ci/evidence/assert

Checks the result of `ci-quality`'s `build` job against vergil-tooling's
BUILD flag, so the quality evidence gate passes only when the build ran
exactly when it should have (epic
[vergil-project/.github#1174](https://github.com/vergil-project/.github/issues/1174)).

The `build` job runs `vrg-validate --check build` only when vergil-tooling
turns the BUILD check on for the repository's language. `vrg-ci-resolve`
reports that as `build-enabled`, which the
[setup action](shared-setup-vergil.md) passes on. A skipped `build` job is
therefore a valid result, so the job cannot be gated by the evidence job's
"every job succeeded" check. This action checks it against the flag instead.

This action is **wired automatically** into the `evidence` job of
`ci-quality`. Consuming repositories do not add it themselves.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ci/evidence/assert@v2.1
  with:
    build-enabled: ${{ needs.matrix.outputs.build-enabled }}
    build-result: ${{ needs.build.result }}
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `build-enabled` | Yes | — | The `matrix` job's `build-enabled` output, `true` or `false`. |
| `build-result` | Yes | — | `needs.build.result`: `success`, `failure`, `cancelled` or `skipped`. |

The action has no outputs.

## Behavior

`build-gate.sh` passes for exactly two pairs and fails with an `::error::`
for every other:

| `build-enabled` | `build-result` | Outcome |
| --------------- | -------------- | ------- |
| `false` | `skipped` | Pass |
| `true` | `success` | Pass |
| `true` | `skipped`, `failure` or `cancelled` | Fail: BUILD is on, but the build did not succeed |
| `false` | `success`, `failure` or `cancelled` | Fail: BUILD is off, but the build job was not skipped |
| anything else | any | Fail: the flag must be `true` or `false` |
| any | anything else | Fail: the result must be one GitHub reports |

An empty flag is an error, never read as off. The setup action already gives
`false` when an older vergil-tooling reports no `build-enabled`, so an empty
flag means the `matrix` job did not run.
