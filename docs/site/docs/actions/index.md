# Action Reference

All actions are composite GitHub Actions located under the `actions/` directory,
organized by pipeline phase. Each action is self-contained with an `action.yml`
definition and optional supporting scripts.

## Available actions

### CI

- **[ci/security/standards-compliance](ci-security-standards-compliance.md)** —
  PR-specific compliance checks: issue linkage and auto-close keyword rejection.
- **[ci/security/codeql](ci-security-codeql.md)** — Runs GitHub CodeQL static
  analysis for a single language.
- **[ci/security/semgrep](ci-security-semgrep.md)** — Runs Semgrep SAST scanning
  with language-specific and cross-cutting security rulesets.
- **[ci/version-bump/version-divergence](ci-version-bump-version-divergence.md)**
  — Verifies that the PR branch version differs from the main branch version.

### CD

- **[cd/release/tag-and-release](cd-release-tag-and-release.md)** — Creates
  annotated git tags and GitHub Releases.
- **[cd/docs/deploy](cd-docs-deploy.md)** — Deploys MkDocs documentation using
  mike for versioned documentation.

### Shared

- **[shared/security/trivy](shared-security-trivy.md)** — Runs Trivy
  vulnerability scanning, SBOM generation, or container image scanning.
- **[shared/setup/system-packages](shared-setup-system-packages.md)** — Installs
  a repository's declared `[container].system-packages` on CI test jobs
  (test-runtime only; auto-wired into `ci-test`).
- **[shared/setup/build-command](shared-setup-build-command.md)** — Runs a
  repository's declared `[container].build-command` on CI test jobs
  (test-runtime only; auto-wired into `ci-test`; fail-closed with no retry;
  exports `NODE_PATH` so a baked out-of-workspace node library resolves).
