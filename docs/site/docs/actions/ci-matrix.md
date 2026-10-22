# ci/matrix

Builds the per-version job matrix for a reusable CI workflow. Each matrix
entry carries the version label, used in the job and check name, and the fully
qualified container image the leg runs in.

The versions, and the image suffix and tag of each, come from the single
resolver, `vrg-ci-resolve`, by way of the outputs of
[`shared/setup/vergil`](shared-setup-vergil.md). This action does no version
or family routing of its own.

This action is **wired automatically** into the `matrix` job of `ci-quality`,
`ci-audit` and `ci-test`. Consuming repositories do not add it themselves.

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
    primary-version: ${{ steps.setup.outputs.primary-version }}
    container-tags: ${{ steps.setup.outputs.container-tags }}
    container-suffixes: ${{ steps.setup.outputs.container-suffixes }}
    container-suffix: python
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `language` | Yes | — | Primary language of the calling repository (e.g. `python`, `cpp`, `shell`). Selects the run-once collapse only. |
| `versions` | Yes | — | The setup action's `versions` output, e.g. `["3.14","3.13"]` or `["clang-20","gcc-14"]`. |
| `primary-version` | Yes | — | The setup action's `primary-version` output. |
| `container-tags` | Yes | — | The setup action's `container-tags` output: version to image tag. |
| `container-suffixes` | Yes | — | The setup action's `container-suffixes` output: version to image suffix. |
| `container-prefix` | No | `prod` | Container image name prefix (`prod` or `dev`). |
| `container-suffix` | No | `""` | The calling workflow's `container-suffix`, used only as a cross-check. When set, it must be one of the resolved suffixes. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `all` | JSON array of `{version, image}` objects, one per resolved version. Used by per-version kinds (TEST always; TYPECHECK for C++ and the single-suffix languages). |
| `once` | The primary version's entry alone for C++ and TypeScript; identical to `all` for every other language. Used by run-once kinds (LINT and AUDIT; TYPECHECK too for TypeScript). |

## Images

Every image is
`ghcr.io/vergil-project/<prefix>-<container-suffixes[v]>:<container-tags[v]>`,
for every language:

| Version | Resolver's suffix and tag | Image |
| ------- | ------------------------- | ----- |
| `clang-20` | `cpp-clang`, `20` | `prod-cpp-clang:20` |
| `gcc-14` | `cpp-gcc`, `14` | `prod-cpp-gcc:14` |
| `node-24` | `ts-node`, `24` | `prod-ts-node:24` |
| `3.14` | `python`, `3.14` | `prod-python:3.14` |
| `latest` (no language) | `base`, `latest` | `prod-base:latest` |

## Failures

The action fails with an `::error::` annotation, and writes no matrix, when:

- an input is empty, or `versions` is not a non-empty JSON array;
- a version has no tag in `container-tags` or no suffix in
  `container-suffixes`;
- `primary-version` is not one of `versions`;
- `container-suffix` is set but is not one of the resolved suffixes. The
  workflow's inputs and the repository's `vergil.toml` then disagree on the
  language (for example `container-suffix: python` with no
  `[project].primary-language`, which resolves to `prod-base:latest`), and the
  legs would run on the wrong image.

## Run-once kinds

For C++ and TypeScript some check kinds run once, on the primary version,
rather than once per version: LINT and AUDIT for C++; LINT, AUDIT and TYPECHECK
for TypeScript. The `once` output gives those jobs a one-entry matrix.

## Implementation

The logic is in `resolve.sh` next to `action.yml`, so it can be unit tested
(`tests/resolve.test.sh`). The step prints both resolved arrays to the job log.
The `smoke-setup-vergil` workflow runs the tests.
