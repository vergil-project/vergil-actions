# Action Reference

All actions are composite GitHub Actions located under the `actions/` directory,
organized by pipeline phase. Each action is self-contained with an `action.yml`
definition and optional supporting scripts.

## Available actions

### CI

- **[ci/security/codeql](ci-security-codeql.md)** — Runs GitHub CodeQL static
  analysis for a single language.
- **[ci/security/semgrep](ci-security-semgrep.md)** — Runs Semgrep SAST scanning
  with language-specific and cross-cutting security rulesets.
- **[ci/version-bump/version-divergence](ci-version-bump-version-divergence.md)**
  — Verifies that the PR branch version differs from the main branch version.
- **[ci/matrix](ci-matrix.md)**
  — Builds the per-version job matrix (version label and container image for
  each entry) from the resolver outputs of `shared/setup/vergil`; auto-wired
  into `ci-quality`, `ci-audit` and `ci-test`.
- **[ci/toolchain/pin-python](ci-toolchain-pin-python.md)** — Pins uv to a
  Python leg's resolved version and to the image's interpreter
  (`UV_PYTHON`, `UV_PYTHON_PREFERENCE=only-system`); auto-wired into the
  Python matrix legs of `ci-quality`, `ci-audit` and `ci-test`.
- **[ci/toolchain/assert](ci-toolchain-assert.md)** — Fails a CI leg whose
  running Python or Go is not the version CI resolved for it; auto-wired into
  the matrix legs of `ci-quality`, `ci-audit` and `ci-test`.
- **[ci/evidence/emit](ci-evidence-emit.md)**
  — Writes a gate's `evidence.json` and uploads it with the gate's report files
  as a `ci-evidence-<gate>` artifact for the release-time evidence bundle.

### CD

- **[cd/release/tag-and-release](cd-release-tag-and-release.md)** — Creates
  annotated git tags and GitHub Releases.
- **[cd/release/validate-inputs](cd-release-validate-inputs.md)**
  — Checks the `cd-release` inputs and fails early on an invalid combination.
- **[cd/release/primary-suffix](cd-release-primary-suffix.md)**
  — Picks the release image suffix from the resolver's primary version.
- **[cd/release/ci-evidence-gate](cd-release-ci-evidence-gate.md)**
  — Pre-publish gate: harvests the release PR's CI evidence artifacts and
  checks they are complete before anything is published.
- **[cd/release/registry-publish](cd-release-registry-publish.md)**
  — Builds the release for the repository's language ecosystem, attests it,
  generates an SBOM and, when enabled, publishes to the package registry.
- **[cd/release/ci-evidence-attach](cd-release-ci-evidence-attach.md)**
  — Post-publish: assembles the evidence bundle including the SBOM, attests it
  and attaches it to the GitHub Release.
- **[cd/docs/deploy](cd-docs-deploy.md)** — Deploys MkDocs documentation using
  mike for versioned documentation.

### Ops

- **[ops/github-config/branch-sweep](ops-github-config-branch-sweep.md)** —
  Deletes branches whose PR is merged or closed and lists them in the job
  summary, flagging merged-PR leftovers (auto-wired into `ops-github-config`).

### Shared

- **[shared/security/trivy](shared-security-trivy.md)** — Runs Trivy
  vulnerability scanning, SBOM generation, or container image scanning.
- **[shared/docs/stage](shared-docs-stage.md)**
  — Stages the changelog and release-notes pages and patches the MkDocs nav,
  so `ci-docs` and `cd-docs` build from the same source tree.
- **[shared/setup/vergil](shared-setup-vergil.md)** — Installs the
  `vergil-tooling` version pinned in `vergil.toml` and resolves the CI version
  set with `vrg-ci-resolve` (`versions`, `primary-version`,
  `primary-container-tag`, `container-tags`, `container-suffixes`; auto-wired
  into the reusable workflows).
- **[shared/setup/system-packages](shared-setup-system-packages.md)** — Installs
  a repository's declared `[container].system-packages` on CI test jobs
  (test-runtime only; auto-wired into `ci-test`).
- **[shared/setup/build-command](shared-setup-build-command.md)** — Runs a
  repository's declared `[container].build-command` on CI test jobs
  (test-runtime only; auto-wired into `ci-test`; fail-closed with no retry;
  exports `NODE_PATH` so a baked out-of-workspace node library resolves).

### Package

- **[package/setup](package-setup.md)** — Installs the package toolchain in a
  package build or install-test container: OS prerequisites (apt mirror list
  on x86_64 Ubuntu, fail-fast apt, a single `apt-get update`), a pinned `uv`,
  `vergil-tooling`, and nFPM.

### Local

Actions used only by this repository's own workflows, not by consumers.

- **[local/freeze-internal-refs](local-freeze-internal-refs.md)**
  — Rewrites this repository's relative `./actions/...` and `@develop` refs to
  absolute refs at the release tag, checks none remain and commits the result
  (used by `cd.yml`).
