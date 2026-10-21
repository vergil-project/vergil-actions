# Vergil Actions

Shared GitHub Actions library providing reusable composite actions for CI/CD
across all managed repositories.

## Status

**Stable (v2.x)** — Actions and reusable workflows are consumed by pinning to
a rolling minor tag (e.g., `@v2.1`), which automatically receives patch
releases.

## Action categories

| Phase | Actions | Purpose |
| ---------- | --------- | --------- |
| CI / Security | [codeql](actions/ci-security-codeql.md), [semgrep](actions/ci-security-semgrep.md) | SAST scanning |
| CI / Version Bump | [version-divergence](actions/ci-version-bump-version-divergence.md) | Pre-merge version validation |
| CI / Matrix | [matrix](https://github.com/vergil-project/vergil-actions/blob/develop/actions/ci/matrix/action.yml) | Per-version job matrix and container images |
| CI / Evidence | [emit](https://github.com/vergil-project/vergil-actions/blob/develop/actions/ci/evidence/emit/action.yml) | Per-gate CI evidence artifact |
| CD / Release | [tag-and-release](actions/cd-release-tag-and-release.md) | Release tagging and GitHub Releases |
| CD / Release | [validate-inputs](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/validate-inputs/action.yml), [ci-evidence-gate](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/ci-evidence-gate/action.yml), [registry-publish](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/registry-publish/action.yml), [ci-evidence-attach](https://github.com/vergil-project/vergil-actions/blob/develop/actions/cd/release/ci-evidence-attach/action.yml) | `cd-release` input checks, pre-publish evidence gate, build and registry publish, post-publish evidence attach |
| CD / Docs | [deploy](actions/cd-docs-deploy.md) | MkDocs Material + mike versioned deployment |
| Ops / GitHub Config | [branch-sweep](actions/ops-github-config-branch-sweep.md) | Delete branches whose PR is merged or closed |
| Shared / Security | [trivy](actions/shared-security-trivy.md) | Vulnerability scanning and SBOM generation |
| Shared / Docs | [stage](https://github.com/vergil-project/vergil-actions/blob/develop/actions/shared/docs/stage/action.yml) | Stage changelog and release-notes pages for the docs build |
| Shared / Setup | [vergil](actions/shared-setup-vergil.md), [system-packages](actions/shared-setup-system-packages.md), [build-command](actions/shared-setup-build-command.md) | vergil-tooling install and CI version set; test-job system packages and build command |
| Package | [setup](actions/package-setup.md) | Package toolchain for package build and install-test containers |
| Local | [freeze-internal-refs](https://github.com/vergil-project/vergil-actions/blob/develop/actions/local/freeze-internal-refs/action.yml) | Pin this repository's internal action refs to the release tag (used only by its own `cd.yml`) |

## Reusable workflows

Reusable workflows provide canonical job and check names across all managed
repositories. See [Reusable Workflows](workflows/index.md) for details.

### CI (pre-merge)

| Workflow | Purpose |
| ---------- | --------- |
| [ci-docs](workflows/ci-docs.md) | Strict MkDocs build of the documentation site |
| [ci-security](workflows/ci-security.md) | Security scanning (CodeQL, Trivy, Semgrep) |
| [ci-quality](workflows/ci-quality.md) | Common linting, language-specific lint and typecheck |
| [ci-audit](workflows/ci-audit.md) | Dependency audit |
| [ci-test](workflows/ci-test.md) | Unit tests |
| [ci-version-bump](workflows/ci-version-bump.md) | Version divergence gate |
| [ci-package](workflows/ci-package.md) | Build and install-test `.deb`/`.rpm` packages (repos with `[package]` only) |

### CD (post-merge)

| Workflow | Purpose |
| ---------- | --------- |
| [cd-release](workflows/cd-release-packages.md) | Full release pipeline (tag, build, publish, version bump), plus signed `.deb`/`.rpm` packages for repos with `[package]` |
| [cd-docs](https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/cd-docs.yml) | MkDocs documentation deployment |
| [publish-index](workflows/publish-index.md) | Signed apt/dnf package-repository site for an `<org>/packages` repo, deployed to GitHub Pages |

## Design principles

- **Composite actions only** — No custom JavaScript or Docker actions. Every
  action is a composite `action.yml` with shell steps.
- **Reusable workflows** — CI and CD workflows are provided as reusable
  `workflow_call` templates that produce canonical check names across all
  consuming repositories.
- **Self-referencing CI** — This repository's own CI uses `./actions/...` and
  `./.github/workflows/...` local paths, so changes are tested by the same PR
  that modifies them.
- **Centralized standards** — Workflow patterns and validation rules are defined
  once here and consumed by all repositories.

## Canonical standards

This repository follows the
[vergil-tooling](https://github.com/vergil-project/vergil-tooling)
repository for commit messages, branching, versioning, and code management
practices.
