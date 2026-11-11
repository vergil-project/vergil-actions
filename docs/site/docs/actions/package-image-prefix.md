# package/image-prefix

Applies a reusable workflow's `container-prefix` to the `build` and `test`
outputs of `vrg-package matrix`. `vrg-package matrix` names every cell's image
`ghcr.io/vergil-project/prod-pkg-<distro>:<version>`. With
`container-prefix: dev` this action rewrites the `prod-pkg-` start of each
image to `dev-pkg-`, so the package jobs run on the development package
images. With the default `prod` both outputs are passed on byte for byte.

This action is **wired automatically** into the `matrix` job of
[`ci-package`](../workflows/ci-package.md#container-prefix) and the
`package-matrix` job of
[`cd-release`](../workflows/cd-release-packages.md). Consuming repositories
do not add it themselves. They set the workflow's `container-prefix` input.

## Usage

```yaml
- name: Resolve package matrix
  id: resolve
  run: vrg-package matrix --github-output

- name: Apply container prefix
  id: images
  uses: vergil-project/vergil-actions/actions/package/image-prefix@v2.1
  with:
    container-prefix: ${{ inputs.container-prefix }}
    build: ${{ steps.resolve.outputs.build }}
    test: ${{ steps.resolve.outputs.test }}
```

The action needs `jq` on `PATH`.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `container-prefix` | No | `prod` | The calling workflow's `container-prefix`: `prod` or `dev`. An empty value means `prod`. |
| `build` | Yes | | The `vrg-package matrix` `build` output: a one-line JSON array of cells. |
| `test` | Yes | | The `vrg-package matrix` `test` output: a one-line JSON array of cells. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `build` | The `build` cells with the prefix applied to each `image`. |
| `test` | The `test` cells with the prefix applied to each `image`. |

## Behavior

- Only the `ghcr.io/vergil-project/prod-pkg-` start of a cell's `image`
  changes. Every other field, and the order of the cells, stays as it was.
- A cell whose image is not under `prod-pkg-` keeps it, with a
  `::warning::`.
- A repo without `[package]` has `[]` outputs, which pass through as `[]`.
- The log lists the image each cell will use.

## Checks

The step fails with an `::error::` annotation, and writes no output, when:

- `container-prefix` is not `prod`, `dev` or empty;
- `build` or `test` is empty;
- `build` or `test` is not a one-line JSON array of objects that each have a
  string `image`.
