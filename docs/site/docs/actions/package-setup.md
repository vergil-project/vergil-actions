# package/setup

Installs the package toolchain inside an arbitrary package build or
install-test container: the OS prerequisites, a pinned `uv`, `vergil-tooling`,
and (for build cells) a checksum-pinned nFPM. The containers are raw `ubuntu`
or UBI images that ship neither Python nor `vergil-tooling`, and must run as
root (the GitHub Actions container default).

This action is **wired automatically** into the `build` and `install-test`
jobs of `ci-package.yml` and the `package-build` jobs of `cd-release.yml`.
Consuming repositories do not add it themselves.

## Usage

```yaml
- uses: actions/checkout@v6
- uses: vergil-project/vergil-actions/actions/package/setup@v2.1
  with:
    nfpm: "true"
```

## Inputs

| Input | Default | Description |
| ----- | ------- | ----------- |
| `nfpm` | `"false"` | Install nFPM. Build cells pass `"true"`; install-test cells leave it off. |

## OS prerequisites

The first step runs `os-prereqs.sh`, which keeps package jobs off slow apt
mirrors and makes any apt stall fail fast instead of hanging the job.

### apt images (Ubuntu, Debian)

1. **Mirror list on x86_64.** The script rewrites the Ubuntu archive and
   security URIs, including any that already point at
   `azure.archive.ubuntu.com`, to `mirror+file:/etc/apt/apt-mirrors.txt`. It
   then writes that file in the format GitHub's hosted runner images use
   ([`configure-apt-sources.sh`](https://github.com/actions/runner-images/blob/main/images/ubuntu/scripts/build/configure-apt-sources.sh)),
   one tab-separated entry per line:

    ```text
    http://azure.archive.ubuntu.com/ubuntu/    priority:1
    http://archive.ubuntu.com/ubuntu/          priority:2
    http://security.ubuntu.com/ubuntu/         priority:3
    ```

    apt tries the in-region Azure mirror first and moves down the list when
    a mirror fails. A failing Azure mirror therefore falls back instead of
    failing the job. On its own, a container image's default,
    `archive.ubuntu.com`, has stalled amd64 package builds for more than ten
    minutes.

    The hosts and priorities match runner-images, with one deliberate
    difference: the fallbacks use `http://`, not `https://`. A fresh
    container has no CA certificates until this script installs
    `ca-certificates`, so an `https://` fallback fails with "No system
    certificates available". `http://` is the image's own default, and apt
    still verifies every index against the archive's signed `InRelease`.

    The script rewrites both the deb822
    `/etc/apt/sources.list.d/ubuntu.sources` (24.04 and later) and the legacy
    `/etc/apt/sources.list`, before the first `apt-get update`. It writes the
    mirror list only when it rewrites a sources file, and overwrites the list
    rather than appending to it, so a re-run is a no-op.
2. **arm64 is left alone.** arm64 images use `ports.ubuntu.com`, which none
   of the listed mirrors serve, and which is already fast. Sources on any
   architecture other than `x86_64` are not touched.
3. **Fail-fast apt.** The script writes
   `/etc/apt/apt.conf.d/80-vergil-fast-fail`:

    ```text
    Acquire::Retries "3";
    Acquire::Retries::Delay "false";
    Acquire::http::Timeout "20";
    Acquire::https::Timeout "20";
    DPkg::Lock::Timeout "60";
    ```

    Every later apt call in the job inherits it, including the ones
    `vergil-tooling` makes during build and install-test.

    `Acquire::Retries::Delay "false"` is required for the mirror list to
    work. With apt's default delayed retries, apt 2.4 to 2.8 (Ubuntu 22.04
    and 24.04) deadlocks after a mirror-list failover: it fetches the
    fallback's `InRelease` files and then waits forever, and the timeouts
    never fire ([LP #2003851](https://bugs.launchpad.net/ubuntu/+source/apt/+bug/2003851)).
    This is what hung `vergil-tooling` CD run 37678748594 for 21,578 seconds
    in `package-sign`, on a runner whose own sources are this mirror list.
    The same hang reproduces in an `ubuntu:24.04` container with the Azure
    mirror unreachable. With undelayed retries, the same failover completes
    in seconds.
4. **One update, one install.** The script runs exactly one `apt-get update`.
   It then installs every prerequisite the package tooling needs in a single
   call: `ca-certificates curl git tar gzip gnupg`. Because they are all
   present, `vergil-tooling`'s own bootstrap does not need to install them
   again.

### dnf images (UBI)

One `dnf install` with `--setopt=retries=3 --setopt=timeout=20` installs
`ca-certificates /usr/bin/curl /usr/bin/gpg git tar gzip`. curl and gpg are
named by path, as `vergil-tooling` names them. UBI ships `curl-minimal`, which
conflicts with the full `curl` package, and a path resolves to whichever
package provides the file.

An image with neither `apt-get` nor `dnf` fails the step.

### Tests

The logic lives in `os-prereqs.sh` rather than inline YAML so that it can be
tested. `actions/package/setup/tests/os-prereqs.test.sh` runs it against
fixture `/etc` trees with recording `apt-get`/`dnf` stubs, so it needs neither
root nor a container. It covers the deb822 x86_64 rewrite and the exact
mirror-list contents, migrating Azure-pinned sources to the list, arm64 left
untouched, the legacy `sources.list`, idempotence across two runs, an x86_64
image with no Ubuntu sources, the dnf path, and package-manager detection.
The `Smoke - setup/vergil outputs` workflow runs it on every PR that touches
this action.

### Job timeouts and the runner host

`package-sign` in `cd-release.yml` installs `rpm` and `gnupg` on the runner
host itself, not in a container. It passes the same fail-fast options on the
command line (`-o Acquire::Retries=3 -o Acquire::Retries::Delay=false
-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20
-o DPkg::Lock::Timeout=60`). Every package job also sets `timeout-minutes`
as a backstop: `matrix` 5, `build` 30, `install-test` 15 and `evidence` 5
in `ci-package.yml`, and `package-matrix` 5, `package-build` 30 and
`package-sign` 15 in `cd-release.yml`.

## Other steps

- **Install uv.** Downloads the release's `uv-installer.sh`, verifies it
  against a pinned sha256, and installs `uv` into `/usr/local/bin`.
- **Install vergil-tooling.** `detect.sh` resolves the install spec. In
  `vergil-tooling` itself it is the checkout, so CI exercises the PR's own
  `vrg-package`. Elsewhere it is `[dependencies].vergil` from `vergil.toml`.
  The tools land in uv's tool bin directory under `$HOME`, never in
  `/usr/local/bin`. That way install-test smoke checks, which run with a
  system-only `PATH`, cannot resolve this copy.
- **Install nFPM** (only when `nfpm: "true"`). Downloads the release tarball
  for the runner's architecture and verifies it against a pinned sha256.
