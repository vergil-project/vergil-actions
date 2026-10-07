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

1. **Azure mirror on x86_64.** The script points the Ubuntu archive and
   security URIs at `http://azure.archive.ubuntu.com/ubuntu/`. This is the
   in-region mirror that GitHub's hosted Ubuntu runner images use for both the
   archive and the `-security` suites. It rewrites the deb822
   `/etc/apt/sources.list.d/ubuntu.sources` (24.04 and later) and the legacy
   `/etc/apt/sources.list`. The rewrite happens before the first
   `apt-get update`. A container image's default, `archive.ubuntu.com`, has
   stalled amd64 package builds for more than ten minutes.
2. **arm64 is left alone.** arm64 images use `ports.ubuntu.com`, which the
   Azure mirror does not serve, and which is already fast. Sources on any
   architecture other than `x86_64` are not touched.
3. **Fail-fast apt.** The script writes
   `/etc/apt/apt.conf.d/80-vergil-fast-fail`:

    ```text
    Acquire::Retries "3";
    Acquire::http::Timeout "20";
    Acquire::https::Timeout "20";
    ```

    Every later apt call in the job inherits it, including the ones
    `vergil-tooling` makes during build and install-test.
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
root nor a container. It covers the deb822 x86_64 rewrite, arm64 left
untouched, the legacy `sources.list`, idempotence, the dnf path, and
package-manager detection. The `Smoke - setup/vergil outputs` workflow runs it
on every PR that touches this action.

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
