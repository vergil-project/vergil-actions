# ci/matrix

Resolves the per-version job matrix for a reusable CI workflow. Each matrix
entry carries the version label, used in the job and check name, and the fully
qualified container image the leg runs in.

This action is **wired automatically** into the `matrix` job of `ci-quality`,
`ci-audit` and `ci-test`, which pass it the `versions` output of
[`shared/setup/vergil`](https://github.com/vergil-project/vergil-actions/blob/develop/actions/shared/setup/vergil/action.yml).
Consuming repositories do not add it themselves.

## Usage

```yaml
- name: Install vergil-tooling
  id: setup
  uses: vergil-project/vergil-actions/actions/shared/setup/vergil@v2.1

- name: Resolve matrix
  id: resolve
  uses: vergil-project/vergil-actions/actions/ci/matrix@v2.1
  with:
    language: python
    versions: ${{ steps.setup.outputs.versions }}
    container-suffix: python
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `language` | Yes | — | Primary language of the calling repository (e.g. `python`, `cpp`, `shell`). Selects the image-routing rule and the run-once collapse. |
| `versions` | Yes | — | JSON array string of version tokens, e.g. `["3.12","3.13","3.14"]` or `["clang-20","gcc-14"]`. |
| `container-prefix` | No | `prod` | Container image name prefix (`prod` or `dev`). |
| `container-suffix` | No | `""` | Container image name suffix for single-suffix languages (e.g. `python`, `go`, `base`), and the runtime family for TypeScript (`ts-node`). Ignored for C++. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `all` | JSON array of `{version, image}` objects, one per configured version. Used by per-version kinds (TEST always; TYPECHECK for C++ and the single-suffix languages). |
| `once` | The same array collapsed to the first version for C++ and TypeScript; identical to `all` for every other language. Used by run-once kinds (LINT and AUDIT; TYPECHECK too for TypeScript). |

## Image routing

Every image is `ghcr.io/vergil-project/<prefix>-<suffix>:<tag>`. How the suffix
and tag are chosen depends on `language`:

| Language | Rule | Example |
| -------- | ---- | ------- |
| `cpp` | The compiler family rides the version token. The token is split at the first `-`: the family goes into the suffix, the rest is the tag. `container-suffix` is ignored. | `clang-20` → `prod-cpp-clang:20` |
| `typescript` | The Node major rides the version token. The suffix is `container-suffix` (or `ts-<family>` when it is empty), and the part after the first `-` is the tag. | `node-24` with suffix `ts-node` → `prod-ts-node:24` |
| Any other | The version is the tag unchanged. The suffix is `container-suffix`, or the language name when it is empty. | `3.14` with suffix `python` → `prod-python:3.14` |

## Run-once kinds

For C++ and TypeScript some check kinds run once, on the first version, rather
than once per version: LINT and AUDIT for C++; LINT, AUDIT and TYPECHECK for
TypeScript. The `once` output gives those jobs a one-entry matrix. This matches
the run-once gates that vergil-tooling's `desired_ci_gates_ruleset()` keys to
`[ci].versions[0]`, so the jobs CI runs and the checks the ruleset requires
stay in step.

## Implementation

The logic is in `resolve.sh` next to `action.yml`, so it can be unit tested
(`tests/resolve.test.sh`). The step prints both resolved arrays to the job log.
