# CI Gate Requirements

This section documents the CI gate configuration for all repositories consuming
vergil-actions. It covers which checks are required and the security scanning
requirements.

## Overview

Every managed repository runs a common set of CI checks on pull requests. CI
workflows trigger on `pull_request` only — push triggers are not used because
branch protection enforces that all changes go through PRs.

Each check comes from a [reusable workflow](../workflows/index.md) called by a
job in the repository's `ci.yml`. GitHub names a reusable-workflow check
`<caller job> / <job>`, so with the standard caller job keys the checks are
grouped by workflow:

| Caller job | Workflow | Purpose | Example checks |
| ------------ | ---------- | --------- | ---------------- |
| `quality` | `ci-quality.yml` | Common linting, custom validation, language lint and typecheck | `quality / common`, `quality / evidence` |
| `security` | `ci-security.yml` | SAST and vulnerability scanning | `security / codeql`, `security / trivy`, `security / semgrep` |
| `audit` | `ci-audit.yml` | Dependency audit | `audit / evidence` |
| `test` | `ci-test.yml` | Unit tests | `test / evidence` |
| `docs` | `ci-docs.yml` | Strict docs build | `docs / docs` |
| `version` | `ci-version-bump.yml` | Version divergence gate | `version / version-bump` |
| `package` | `ci-package.yml` | `.deb`/`.rpm` build and install-test | `package / evidence` |

## Key concepts

- **Reusable workflows** — v2.0.0 introduced
  [reusable CI workflows](../workflows/index.md) that produce the canonical
  check names automatically. Consuming repositories call these workflows
  rather than assembling jobs by hand.
- **Required status checks** — Configured in GitHub repository rulesets.
  PRs cannot merge until all required checks pass.
- **Self-referencing CI** — The vergil-actions repository tests its own
  actions using local paths (`./actions/...`).

## Pages in this section

- [The All-Hard-Gates Principle](all-hard-gates.md) — Why every check that
  matters is a hard, asserting gate and there are no report-only/warning gates
- [Required Checks](required-checks.md) — Which checks are required, and
  the check names each reusable workflow produces
- [Repository Rulesets](repository-rulesets.md) — Branch protection, CI gates,
  and tag protection ruleset configuration
- [Security Scanning](security-scanning.md) — CodeQL, Semgrep, and Trivy
  configuration details
