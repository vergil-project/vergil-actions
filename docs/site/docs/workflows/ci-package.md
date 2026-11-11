# ci-package

Build and install-test a repo's binary OS packages (`.deb`/`.rpm`) from its
`[package]` section.

## Tiered matrix

`ci-package.yml` is called only by repos whose `vergil.toml` has a `[package]`
section. Calling it without one fails the run. Its gate job surfaces as
`package / evidence` under a caller job keyed `package`.

The `matrix` job picks a tier and passes it to
`vrg-package matrix --github-output --tier <tier>`:

| Event | Tier |
| ----- | ---- |
| Pull request from `release/*` into `main` | `full` |
| Any other pull request | `reduced` |
| Any non-PR event (`push`, `workflow_dispatch`, …) | `full` |

The `reduced` tier keeps every build cell but runs only one `install-test`
leg per format, so feature PRs get feedback sooner. For each format it picks
from that format's shared (non-`native`) targets, or from its `native` ones if
it has no shared target. It prefers amd64 (falling back to arm64) and takes
the **oldest** release, compared numerically: the strictest compatibility case
(lowest glibc, oldest rpm/dnf/systemd). The selection is done by
vergil-tooling's `vrg-package matrix` (`lib/package/matrix.py`).

Release PRs always run the `full` tier, and the release evidence harvest reads
the release PR's CI. A caller can override the automatic choice
with the optional `package-tier` input (`auto`, `full` or `reduced`; default
`auto`). Any other value fails the `matrix` job.

```yaml
jobs:
  package:
    uses: vergil-project/vergil-actions/.github/workflows/ci-package.yml@v2.1
    with:
      package-tier: full  # optional; omit for auto
```

`package / evidence` runs in both tiers. It fails unless the `matrix`, `build`
and `install-test` jobs all succeeded, and it records the tier that ran as
`metrics.tier` in the `ci-evidence-package` artifact.

This needs a vergil-tooling release whose `vrg-package matrix` accepts `--tier`.

## Build runtime

For `builder = "python"`, `vrg-package matrix` resolves the `vergil-python`
runtime once and records it as `runtime` on every build cell
([vergil-tooling#3478](https://github.com/vergil-project/vergil-tooling/issues/3478)).
Each `build / <cell>` job passes it on as
`vrg-package build --cell <cell> --runtime <runtime>`, as `cd-release.yml`'s
`package-build` does, so PR builds and release builds use the same runtime on
every architecture. A cell without a `runtime` (a non-python builder) passes
an empty `--runtime`, never `null`, which `vrg-package build` reads as none
recorded. This needs vergil-tooling 2.1.262 or later at the caller's
`[dependencies].vergil` pin; `v2.1` resolves to it.

## Toolchain setup

Each `build / <cell>` and `install-test / <cell>` job runs inside the cell's
package toolchain image (`prod-pkg-ubuntu` or `prod-pkg-rhel`, which the
caller's vergil-tooling names, or their `dev-pkg-` variants with
[`container-prefix: dev`](#container-prefix)) and sets it up with
[`package/setup`](../actions/package-setup.md). That action checks the image
against its `/etc/vergil/package-toolchain` marker and installs
`vergil-tooling`; it installs no toolchain itself, so a cell in a raw image
fails at once. The `prod-pkg-ubuntu` image carries the apt mirror list (on
amd64) and a fail-fast apt config (3 undelayed retries, 20-second timeouts,
a 60-second dpkg lock wait) that every apt call in the job inherits.

Every package job sets `timeout-minutes`, in both `ci-package.yml` (`matrix`
5, `build` 30, `install-test` 15, `evidence` 5) and `cd-release.yml`
(`package-matrix` 5, `package-build` 30, `package-sign` 15). A normal build
takes about 45 seconds, so a stall fails the job in minutes rather than
running to GitHub's 6-hour limit.

## Container prefix

`vrg-package matrix` names every cell's image
`ghcr.io/vergil-project/prod-pkg-<distro>:<version>`. The optional
`container-prefix` input (`prod` or `dev`; default `prod`, which an empty
value also means) picks the image
variant: with `dev`, the `matrix` job rewrites the `prod-pkg-` start of each
image in its `build` and `test` outputs to `dev-pkg-`, so the build and
install-test jobs run on the development package images. Nothing else in the
outputs changes, and with `prod` they are passed on unchanged. Any other
value, or a missing or malformed `vrg-package matrix` output, fails the
`matrix` job. The job log lists the image each cell will use.

```yaml
jobs:
  package:
    uses: vergil-project/vergil-actions/.github/workflows/ci-package.yml@v2.1
    with:
      container-prefix: dev  # optional; omit for prod
```
