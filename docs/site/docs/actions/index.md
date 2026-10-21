# Action Reference

All actions are composite GitHub Actions located under the `actions/` directory,
organized by pipeline phase. Each action is self-contained with an `action.yml`
definition and optional supporting scripts.

Actions without a page of their own link to their `action.yml`, whose `inputs`
and `outputs` descriptions are the reference.

## Available actions

### CI

- **[ci/security/codeql](ci-security-codeql.md)** — Runs GitHub CodeQL static
  analysis for a single language.
- **[ci/security/semgrep](ci-security-semgrep.md)** — Runs Semgrep SAST scanning
  with language-specific and cross-cutting security rulesets.
- **[ci/version-bump/version-divergence](ci-version-bump-version-divergence.md)**
  — Verifies that the PR branch version differs from the main branch version.
- **[ci/matrix](https://github.com/vergil-project/vergil-actions/blob/develop/actions/ci/matrix/action.yml)**
  — Resolves the per-version job matrix (version label and container image for
  each entry) from the `versions` output of `shared/setup/vergil`; auto-wired
  into `ci-quality`, `ci-audit` and `ci-test`.
- **[ci/evidence/emit](https://github.com/vergil-project/vergil-actions/blob/develop/actions/ci/evidence/emit/action.yml)**
  — Writes a gate's `evidence.json` and uploads it with the gate's report files
  as a `ci-evidence-<gate>` artifact for the release-time evidence bundle.

### CD

- **[cd/release/tag-and-release](cd-release-tag-and-release.md)** — Creates
  annotated git tags and GitHub Releases.
- **[cd/release/validate-inputs](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/validate-inputs/action.yml)**
  — Checks the `cd-release` inputs and fails early on an invalid combination.
- **[cd/release/ci-evidence-gate](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/ci-evidence-gate/action.yml)**
  — Pre-publish gate: harvests the release PR's CI evidence artifacts and
  checks they are complete before anything is published.
- **[cd/release/registry-publish](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/registry-publish/action.yml)**
  — Builds the release for the repository's language ecosystem, attests it,
  generates an SBOM and, when enabled, publishes to the package registry.
- **[cd/release/ci-evidence-attach](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/ci-evidence-attach/action.yml)**
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
- **[shared/docs/stage](https://github.com/vergil-project/vergil-actions/blob/develop/actions/shared/docs/stage/action.yml)**
  — Stages the changelog and release-notes pages and patches the MkDocs nav,
  so `ci-docs` and `cd-docs` build from the same source tree.
- **[shared/setup/vergil](shared-setup-vergil.md)** — Installs the
  `vergil-tooling` version pinned in `vergil.toml` and derives the CI version
  set (`versions`, `primary-version`, `primary-container-tag`) from `[ci]`
  (auto-wired into the reusable workflows).
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

- **[local/freeze-internal-refs](https://github.com/vergil-project/vergil-actions/blob/develop/actions/local/freeze-internal-refs/action.yml)**
  — Rewrites this repository's relative `./actions/...` and `@develop` refs to
  absolute refs at the release tag, checks none remain and commits the result
  (used by `cd.yml`).
