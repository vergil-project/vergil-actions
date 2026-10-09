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

## Toolchain setup

Each `build / <cell>` and `install-test / <cell>` job runs inside the cell's
OS image and sets it up with
[`package/setup`](../actions/package-setup.md). On x86_64 Ubuntu images
that action points apt at a mirror list, as GitHub's hosted runners do: the
Azure mirror first, then `archive.ubuntu.com` and `security.ubuntu.com` as
fallbacks. On every apt image it writes a fail-fast apt config (3 undelayed
retries, 20-second timeouts, a 60-second dpkg lock wait) that all later apt
calls in the job inherit, and it runs a single `apt-get update`. arm64 cells
keep `ports.ubuntu.com`. UBI cells install through one bounded `dnf` call.

Every package job sets `timeout-minutes`, in both `ci-package.yml` (`matrix`
5, `build` 30, `install-test` 15, `evidence` 5) and `cd-release.yml`
(`package-matrix` 5, `package-build` 30, `package-sign` 15). A normal build
takes about 45 seconds, so a stall fails the job in minutes rather than
running to GitHub's 6-hour limit.
