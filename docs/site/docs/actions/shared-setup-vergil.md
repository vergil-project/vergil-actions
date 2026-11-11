# shared/setup/vergil

Installs `vergil-tooling` at the version the repository pins in `vergil.toml`,
then resolves the repository's CI version set by calling `vrg-ci-resolve`, the
single resolver that ships with it. Reusable workflows read their version
matrix and container tags from this action's outputs instead of from
hard-coded inputs.

This action is **wired automatically** into the reusable workflows: every job
that runs a `vrg-*` command, and the `matrix` and `setup` jobs that resolve the
version set. Consuming repositories do not add it themselves. It is documented
here for operators who need to understand what the step does and why a job
might fail inside it.

## Usage

```yaml
- uses: actions/checkout@v6

- name: Install vergil-tooling
  id: setup
  uses: vergil-project/vergil-actions/actions/shared/setup/vergil@v2.1
```

The repository must be checked out first: the action reads `vergil.toml` (and,
to detect vergil-tooling itself, `pyproject.toml`) from the working directory.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `install-source` | No | `auto` | `auto` chooses the install path from the tag and the environment (below). `git` always installs vergil-tooling with `uv tool install` from git and never touches the vergil apt repository; with a line pin (`vX.Y`) it installs the newest `vX.Y.Z` release tag in that line rather than the floating `vX.Y` tag. `publish-index`'s `build-index` job sets it, because it rebuilds that repository's index and must not install from the index it is about to repair. Any other value fails the job. |
| `version-window` | No | `""` | Path to a local `window.json` for the resolver to read instead of the published window. When set, the Derive step exports it as `VRG_VERSION_WINDOW`, the resolver's one sanctioned override. For tests only: leave it empty in real workflows. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `versions` | The resolved versions, newest first, as a compact JSON array string, e.g. `["3.14","3.13","3.12"]`. The `matrix` job passes it to [`ci/matrix`](ci-matrix.md) to fan out per-version legs. |
| `primary-version` | `[ci].primary-version` when it is set; otherwise the newest resolved version. |
| `primary-container-tag` | The resolver's image tag for the primary version (`clang-20` has tag `20`, `node-24` has `24`, `3.14` has `3.14`). Used by the single-container `common` and `custom` jobs in `ci-quality`, the `version-bump` job in `ci-version-bump` and the `release` job in `cd-release`. |
| `container-tags` | Compact JSON object mapping each resolved version to its image tag, e.g. `{"clang-20":"20","gcc-14":"14"}`. Passed to [`ci/matrix`](ci-matrix.md). |
| `container-suffixes` | Compact JSON object mapping each resolved version to its image suffix, e.g. `{"clang-20":"cpp-clang","gcc-14":"cpp-gcc"}`. Passed to [`ci/matrix`](ci-matrix.md), and to [`shared/setup/primary-suffix`](shared-setup-primary-suffix.md) for the single-container jobs' image suffix. |

## Behavior

The action runs these steps in order:

1. **Mark the workspace safe for git.** Adds the workspace to git's
   `safe.directory` list, because inside a container the workspace is owned by
   a different UID than the user git runs as.
2. **Install vergil-tooling.** `install-tooling.sh` chooses the install path
   by explicit checks, logs the one it took (each log line starts
   `vergil-tooling:`), and fails the job when the chosen path fails. Nothing
   falls back to another path after a failure.
    - If `pyproject.toml` declares `name = "vergil-tooling"`, the repository is
      vergil-tooling itself. The step runs `uv sync --frozen --group dev` and
      adds `.venv/bin` to `PATH`, so CI tests the PR's own code rather than a
      released version. The sync runs with `UV_PYTHON_PREFERENCE=only-system`,
      so it uses the system (image or runner) interpreter and never downloads a managed one
      (issue #1002). `uv tool install` needs no such pin, because uv tool
      commands ignore a project's uv settings.
    - Otherwise it reads `[dependencies].vergil` from `vergil.toml` (e.g.
      `v2.1`) and installs vergil-tooling at that tag:
        - **`install-source: git`:** `uv tool install` from git. A release
          line pin (`vX.Y`) installs the newest `vX.Y.Z` tag in that line,
          listed with `git ls-remote`, not the floating `vX.Y` tag: a release
          dispatches the package-index rebuild before it moves `vX.Y`, and
          the rebuild must run the release that triggered it (issue #1144).
          A failed tag lookup, or a line with no `vX.Y.Z` tag, fails the job;
          it never falls back to `vX.Y`. An exact or dev pin installs at that
          tag.
        - **A dev tag** (anything but `vX.Y` or `vX.Y.Z`, such as `develop`):
          `uv tool install` from git. Where the job has both the vergil apt
          source (`/etc/apt/sources.list.d/vergil.sources`) and a core Python
          (`/opt/vergil/python/<series>/bin/python3`), it runs on the core
          Python (`--python`); where it has neither, uv chooses the
          interpreter, as before; where it has only one, or more than one core
          Python, the job fails.
        - **A release line or exact release in a container job:** where the
          image has both the vergil apt source and a core Python, the
          packaged install from the vergil apt repository; where it has
          neither, `uv tool install` from git; where it has only one, the job
          fails rather than guess.
        - **A release line or exact release in a host job** (no
          `/.dockerenv`): the vergil apt repository is set up on the runner
          the way vergil-tooling's `repo_setup.bootstrap` does it. The runner's
          Ubuntu codename must be a registered package target (`noble` or
          `resolute`). The published key must hold exactly one primary key
          whose fingerprint is `B3A1D804DC03AB036566A4E367861822166ECABE`,
          checked before any apt source is written. The
          `vergil-archive-keyring` package is installed from a temporary
          bootstrap source, which is then removed. When the keyring is already
          installed, its key is checked against the same fingerprint instead.
          Then the packaged install.

      The packaged install pins vergil-tooling to the tag in
      `/etc/apt/preferences.d/vergil-tooling` and checks apt's candidate
      against it: a version starting `X.Y.` for a line, exactly `X.Y.Z-1` for
      an exact release. A mismatch fails the job with nothing installed.
      After the install, `vrg-whoami` must resolve to `/usr/bin/vrg-whoami`,
      run on a venv whose interpreter is under `/opt/vergil/python/`, and run.

      A path that needs `uv` and finds none on `PATH` installs uv from its
      release tarball at the version and SHA-256 pinned in
      `install-tooling.sh`, into `$RUNNER_TEMP/uv/bin`, and adds that to
      `PATH`. uv is never installed with `pip`.

      The tag is read by `read-pin.sh`, which fails the job with a single
      `::error::` annotation naming the file or key, and nothing is installed,
      when:
        - `vergil.toml` does not exist (usually because the repository was
          not checked out first);
        - `vergil.toml` is not valid TOML (the annotation includes the parse
          error);
        - there is no `[dependencies]` table, or `dependencies` is not a
          table;
        - `[dependencies]` has no `vergil` key;
        - `[dependencies].vergil` is not a string, or is empty or blank.

      Apart from the TOML parse error, each annotation says what to add: a pin
      such as

      ```toml
      [dependencies]
      vergil = "v2.1"
      ```

3. **Derive the CI versions.** Runs `derive.sh`, which calls
   `vrg-ci-resolve --format json` once and writes its answer to the five
   outputs. The resolution itself is not done here: the resolver reads
   `vergil.toml` and the language version window that `vergil-containers`
   publishes at the `[dependencies].vergil` ref, and applies the rules:
    - `repository-type = "library"` builds the whole window; every other type
      resolves as an app, which builds exactly one version: the newest, or
      its single `[ci].versions` pin;
    - C++ and TypeScript must pin `[ci].versions` until their lifecycle turn:
      their versions carry a family (`clang-`/`gcc-`, `node-`), so there is no
      single default;
    - a packaged Python app (`[package].builder = "python"`) builds the newest
      version that has a published `vergil-python` runtime; a packaged
      library keeps the whole window (only its deployed runtime needs a
      published package);
    - a `[ci].versions` pin must lie inside the window, and an app's pin must
      name one version;
    - `[ci].primary-version` must name a resolved version; without it the
      primary is the newest resolved version;
    - a repository with no `[project].primary-language` builds `latest` on the
      base image.

   Any resolver failure fails the job, and every line of the resolver's
   message becomes an `::error::` annotation. That includes a window that
   cannot be fetched or is invalid, a pin outside the window, an app that
   pins more than one version, a C++ or TypeScript repository with no pin, a
   packaged Python repository with no published runtime among its versions,
   an invalid `primary-version`, and a missing or invalid `vergil.toml`. It
   also fails when `vrg-ci-resolve` is not on `PATH` (a `[dependencies].vergil`
   pin older than vergil-tooling 2.1.253). There is no fallback. A resolver
   stderr line starting `warning:` becomes a `::warning::` annotation and does
   not fail the job (the resolver prints none today).

The install, the pin reading and the derivation live in `install-tooling.sh`,
`read-pin.sh` and `derive.sh` rather than inline YAML so they can be unit
tested; see `tests/install-tooling.test.sh`, which runs every install path
against stubbed apt, gpg, curl and uv under a temporary root, and
`actions/shared/setup/vergil/tests/derive.test.sh`, which runs the real
resolver against the fixture window in `tests/fixtures/window.json` (one case
stubs the resolver to test the `warning:` passthrough), and
`tests/read-pin.test.sh`. The `smoke-setup-vergil` workflow runs those tests
and checks the action's outputs end to end.

## Configuration

The action and the resolver read these parts of the consuming repository's
`vergil.toml`:

```toml
[project]
repository-type = "library"   # library: the whole window; otherwise one version
primary-language = "python"

[dependencies]
vergil = "v2.1"               # vergil-tooling tag to install, and window ref

[ci]
# versions = ["3.14"]         # optional pin inside the window; one entry for an app
# primary-version = "3.13"    # optional; defaults to the newest resolved version
```

Leave `[ci].versions` out so the repository follows the window. Set
`[ci].primary-version` only when the primary version must not be the newest
resolved version.

## Related

- [`ci-test` reusable workflow](../workflows/ci-test.md) — uses the `versions`
  output to build its matrix.
- [`shared/setup/system-packages`](shared-setup-system-packages.md) and
  [`shared/setup/build-command`](shared-setup-build-command.md) — test-job
  steps that run after this one and need `vergil-tooling` on `PATH`.
- [`package/setup`](package-setup.md) — checks the package toolchain image
  and installs only `vergil-tooling` in package build and install-test
  containers instead.
