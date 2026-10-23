# shared/setup/primary-suffix

Picks the image suffix of a single-container job from the resolver's answer:
the primary version's entry in the [setup action](shared-setup-vergil.md)'s
`container-suffixes` output. With the resolver's `primary-container-tag`, the
job's image is the one CI's primary leg runs on, for example
`prod-cpp-clang:20` for `clang-20`.

This action is **wired automatically** into the `setup` jobs of
[`ci-quality`](../workflows/ci-quality.md) (for the `common` job),
[`ci-version-bump`](../workflows/ci-version-bump.md) (for the `version-bump`
job) and [`cd-release`](../workflows/cd-release.md) (for the `release` job).
Consuming repositories do not add it themselves.

## Usage

```yaml
- name: Resolve the primary version with vrg-ci-resolve
  id: derive
  uses: vergil-project/vergil-actions/actions/shared/setup/vergil@v2.1

- name: Resolve primary-container-suffix
  id: suffix
  uses: vergil-project/vergil-actions/actions/shared/setup/primary-suffix@v2.1
  with:
    primary-version: ${{ steps.derive.outputs.primary-version }}
    container-suffixes: ${{ steps.derive.outputs.container-suffixes }}
    container-suffix: ${{ inputs.container-suffix }}
```

The action needs `jq` on `PATH`.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `primary-version` | Yes | | The setup action's `primary-version` output. |
| `container-suffixes` | Yes | | The setup action's `container-suffixes` output: a JSON object mapping each resolved version to its image suffix. |
| `container-suffix` | No | `""` | The calling workflow's `container-suffix`, as a cross-check only. It never changes the output. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `primary-container-suffix` | The primary version's image suffix (e.g. `cpp-clang`, `ts-node`, `python`, `base`). |

## Checks

The step fails with an `::error::` annotation when:

- `primary-version` or `container-suffixes` is empty;
- `container-suffixes` is not a JSON object, or has no suffix for the primary
  version;
- `container-suffix` is set and does not equal the primary version's suffix.
  The calling workflow (`ci.yml` or `cd.yml`) and `vergil.toml`
  (`[project].primary-language`, `[ci]`) disagree on the language, and a job
  on the wrong image could check, build or publish the wrong thing.

Unlike [ci/matrix](ci-matrix.md), which accepts any resolved suffix because it
runs every version, these jobs run only on the primary version, so the
caller's suffix must be the primary version's.
