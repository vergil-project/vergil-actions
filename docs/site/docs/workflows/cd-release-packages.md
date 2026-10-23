# cd-release: binary packages

When the caller's `vergil.toml` has a `[package]` section, `cd-release.yml`
also builds, signs and attaches the repo's `.deb`/`.rpm` packages:

| Job | Behavior |
| --- | -------- |
| `package-matrix` | Always runs. `vrg-package check-unpublished --version <version>` first refuses the release if any package it would publish (same name, full version, arch and format) was already published by an earlier release; a repo without `[package]` passes. Then `vrg-package matrix --github-output --manifest packages-manifest.json` resolves the build cells and writes the release manifest. For `builder = "python"` it resolves the `vergil-python` runtime once and records it as `runtime` on every build cell and in the manifest. |
| `package-build / <cell>` | One job per build cell, on the cell's runner inside its build OS image, with the same toolchain as `ci-package.yml`. It runs `vrg-package build --cell <cell> --runtime <runtime>` with the cell's recorded `runtime`, so every cell builds on the same runtime. A cell without one (a non-python builder) passes an empty `--runtime`, never `null`. The packages are unsigned. |
| `package-sign` | Declares the `package-signing` environment. Before signing anything it runs `vrg-package check-runtime --manifest packages-manifest.json --artifacts dist/packages`, which fails unless every `.deb` and `.rpm` depends on exactly the runtime the manifest records (a manifest without a runtime passes). It then signs every `.rpm` with the org signing subkey and verifies each signature, then attests the provenance of every package. |
| `release` | Runs only if `package-sign` succeeded. It attaches the signed packages and `packages-manifest.json` to the Release, then dispatches `package-released` to `<owner>/packages`. |

A re-published package version, a failed build cell, a mixed-runtime package
set or a failed signing step stops `release` before anything is published or
tagged. The runtime check
([vergil-tooling#3478](https://github.com/vergil-project/vergil-tooling/issues/3478))
catches cells that built on different runtimes, as vergil-tooling 2.1.258 did
(amd64 on `vergil-python3.15`, arm64 on `vergil-python3.14`). The `--runtime`
and `check-runtime` options need vergil-tooling 2.1.262 or later at the
caller's `[dependencies].vergil` pin; `v2.1` resolves to it. The re-publish check is
the CD backstop for a release that did not go through `vrg-release` preflight,
which runs the same check: a package version published twice breaks the shared
package index for every repo. Any `gh` error fails the check rather than
skipping it. The dispatch is deferred: if minting the App token or the
dispatch fails, the release still stands. The index's weekly reconcile picks
it up, and `vrg-release` reports the miss. Repos without `[package]` see only
the extra `package-matrix` job. The other package jobs are skipped, and they
never reference the `package-signing` environment.

A packaged repo needs:

- **A `package-signing` environment.** Its deployment-branch policy must admit
  only `main`. It holds the `PACKAGE_SIGNING_KEY` secret (the ASCII-armored
  export of the signing subkey) and `PACKAGE_SIGNING_PASSPHRASE`. If the key
  is missing or empty, `package-sign` fails.
- **`secrets: inherit` on the caller (required).** Environment secrets reach
  a job in a cross-repo reusable workflow **only** when the caller passes
  `secrets: inherit`. An explicit `secrets:` map, or passing nothing, delivers
  an empty value; declaring the secret in the callee makes no difference
  (verified by a controlled probe, vergil-project/packages#6). Semgrep's
  `secrets-inherit` rule flags this, so suppress it on that line with a
  justification (`# nosemgrep: …`; honored by the SARIF gate since
  vergil-project/vergil-tooling#3107). `inherit` also forwards the org App
  secrets `APP_CLIENT_ID` and `APP_PRIVATE_KEY`, which the index dispatch
  needs. The App must be installed on
  `<owner>/packages` with permission to create repository dispatches
  (`contents: write`).
- **The same permissions the release job already needs.** The package jobs
  request only `contents: read`, `id-token: write` and `attestations: write`:

```yaml
jobs:
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    permissions:
      contents: write
      id-token: write
      attestations: write
      actions: read
    with:
      language: python
    # Required: environment secrets only reach the reusable workflow with inherit.
    secrets: inherit  # nosemgrep: yaml.github-actions.security.secrets-inherit.secrets-inherit
```
