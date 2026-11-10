# package/setup

Checks a package toolchain image and installs `vergil-tooling` in it, inside a
package build or install-test container. Package jobs run only in a vergil
package toolchain image, `prod-pkg-ubuntu` or `prod-pkg-rhel`, built by
vergil-containers (epic
[vergil-project/.github#607](https://github.com/vergil-project/.github/issues/607)).
The image ships the OS prerequisites, `uv` and nFPM preinstalled, but no
Python and no `vergil-tooling`. The container must run as root (the GitHub
Actions container default).

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
| `nfpm` | `"false"` | Require nFPM in the toolchain image. Build cells pass `"true"`; install-test cells leave it off. |
| `python` | `"3.15"` | Python version for the driver `vergil-tooling`. It is the only place the version is written: the install step passes it to `uv tool install --python` and to `detect.sh` as `VRG_DRIVER_PYTHON`. |

## Steps

1. **Check the toolchain image.** `check-toolchain.sh` checks the image
   against its marker file, `/etc/vergil/package-toolchain` (with `--nfpm`
   when `nfpm: "true"`). The step then adds the workspace to git's
   `safe.directory`.
2. **Install vergil-tooling.** `detect.sh` resolves the install spec. In
   `vergil-tooling` itself it is the checkout, so CI exercises the PR's own
   `vrg-package`. Elsewhere it is `[dependencies].vergil` from `vergil.toml`,
   read with `uv run --no-config` under a uv-managed Python of the `python`
   input's version. `detect.sh` fails if `VRG_DRIVER_PYTHON` is unset or empty;
   there is no default. `--no-config` ignores the repository's uv settings
   (`[tool.uv]`, `uv.toml`), so settings such as `python-downloads = "manual"`
   cannot stop the download. The tools land in uv's tool bin directory under
   `$HOME`, never in `/usr/local/bin`. That way install-test smoke checks,
   which run with a system-only `PATH`, cannot resolve this copy.

The action installs no OS packages, `uv` or nFPM itself. A job in a raw
`ubuntu` or UBI image fails at the first step:

```text
::error::package jobs require a vergil package toolchain image; /etc/vergil/package-toolchain not found
```

## The marker contract

The image writes one `<tool> <version>` line per tool, separated by a single
space. `<tool>` is a command name. `<version>` is the first
`[0-9]+(\.[0-9]+)+` token of the standard output of `<tool> --version`. The
marker always lists `uv`, `nfpm`, `curl`, `git`, `gpg`, `tar` and `gzip`:

```text
uv 0.12.23
nfpm 2.47.0
curl 8.5.0
git 2.43.0
gpg 2.4.4
tar 1.35
gzip 1.12
```

`check-toolchain.sh` passes only when the marker lists `uv`, `curl`, `git`,
`gpg`, `tar` and `gzip`, every listed tool is on `PATH` at its listed version
and, with `--nfpm`, the marker lists `nfpm`. `nfpm` is required only with
`--nfpm`, since install-test cells need no nFPM. The script never falls back
to installing anything. It fails the job with one `::error::` line per
problem, after checking every line, if the marker is missing, leaves out a
required tool, or lists a tool that is missing, at another version, or prints
no version. It also fails if `nfpm` is needed but not listed, or if the marker
is empty, malformed or lists a tool twice.

`actions/package/setup/tests/check-toolchain.test.sh` exercises the script
against fixture markers (`VRG_TOOLCHAIN_MARKER`) and stub tools, with no root
and no container. The `Smoke - setup/vergil outputs` workflow runs it on
every PR that touches this action.

## apt behaviour

The apt mirror list (on amd64) and the fail-fast apt config
(`/etc/apt/apt.conf.d/80-vergil-fast-fail`, on every architecture) are part of
the `prod-pkg-ubuntu` image, so every apt call `vergil-tooling` makes during
build and install-test inherits them. vergil-containers writes them, and
checks them when it builds the image.

## Job timeouts and the runner host

`package-sign` in `cd-release.yml` installs `rpm` and `gnupg` on the runner
host itself, not in a container. It passes fail-fast options on the
command line (`-o Acquire::Retries=3 -o Acquire::Retries::Delay=false
-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20
-o DPkg::Lock::Timeout=60`). `Acquire::Retries::Delay "false"` avoids an apt
2.4 to 2.8 deadlock after a mirror failover, in which the timeouts never fire
([LP #2003851](https://bugs.launchpad.net/ubuntu/+source/apt/+bug/2003851)).
Every package job also sets `timeout-minutes` as a backstop: `matrix` 5,
`build` 30, `install-test` 15 and `evidence` 5 in `ci-package.yml`, and
`package-matrix` 5, `package-build` 30 and `package-sign` 15 in
`cd-release.yml`.
