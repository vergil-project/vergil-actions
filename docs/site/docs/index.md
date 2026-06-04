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
| CI / Security | [standards-compliance](actions/ci-security-standards-compliance.md), [codeql](actions/ci-security-codeql.md), [semgrep](actions/ci-security-semgrep.md) | Compliance checks and SAST scanning |
| CI / Version Bump | [version-divergence](actions/ci-version-bump-version-divergence.md) | Pre-merge version validation |
| CD / Release | [tag-and-release](actions/cd-release-tag-and-release.md) | Release tagging and GitHub Releases |
| CD / Docs | [deploy](actions/cd-docs-deploy.md) | MkDocs Material + mike versioned deployment |
| Shared / Security | [trivy](actions/shared-security-trivy.md) | Vulnerability scanning and SBOM generation |
| Shared / Setup | [vergil-tooling](actions/index.md) | Standard-tooling and environment setup |

## Reusable workflows

Reusable workflows provide canonical job and check names across all managed
repositories. See [Reusable Workflows](workflows/index.md) for details.

### CI (pre-merge)

| Workflow | Purpose |
| ---------- | --------- |
| [ci-security](workflows/ci-security.md) | Standards compliance and security scanning |
| [ci-quality](workflows/ci-quality.md) | Common linting, language-specific lint and typecheck |
| [ci-audit](workflows/ci-audit.md) | Dependency audit |
| [ci-test](workflows/ci-test.md) | Unit and integration tests |
| [ci-version-bump](workflows/ci-version-bump.md) | Version divergence gate |

### CD (post-merge)

| Workflow | Purpose |
| ---------- | --------- |
| cd-release | Full release pipeline (tag, build, publish, version bump) |
| cd-docs | MkDocs documentation deployment |

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
