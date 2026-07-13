# CI Gate Requirements

This section documents the CI gate configuration for all repositories consuming
vergil-actions. It covers which checks are required and the security scanning
requirements.

## Overview

Every managed repository runs a common set of CI checks on pull requests. CI
workflows trigger on `pull_request` only — push triggers are not used because
branch protection enforces that all changes go through PRs. These checks are
organized by category using job name prefixes:

| Prefix | Purpose | Example jobs |
| -------- | --------- | ------------- |
| `ci:` | Code quality and standards validation | `ci: standards-compliance`, `ci: actionlint` |
| `security:` | SAST and vulnerability scanning | `security: codeql`, `security: semgrep` |
| `test:` | Unit and integration tests | `test: unit`, `test: integration` |
| `release:` | Release gate validations | `release: gates` |

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
- [Required Checks](required-checks.md) — Matrix of checks by repository
  category
- [Repository Rulesets](repository-rulesets.md) — Branch protection, CI gates,
  and tag protection ruleset configuration
- [Security Scanning](security-scanning.md) — CodeQL, Semgrep, and Trivy
  configuration details
