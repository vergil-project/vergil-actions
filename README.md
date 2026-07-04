# Standard Actions

Shared GitHub Actions library for reusable CI and automation across
repositories.

## Table of Contents

- [Purpose](#purpose)
- [Repository layout](#repository-layout)
- [Branching and releases](#branching-and-releases)
- [Versioning](#versioning)
- [Validation](#validation)

## Purpose

Provide a centralized, versioned set of GitHub Actions that can be reused across
application and library repositories without workflow drift.

## Repository layout

```text
actions/                          Composite GitHub Actions
  docs-deploy/                    MkDocs + mike versioned deployment
  publish/                        Release tagging and version bumps
  python/setup/                   Python environment with uv and caching
  release-gates/                  Pre-merge version validation
  security/                       CodeQL, Semgrep, Trivy scanning
  setup/vergil-tooling/         vergil-tooling CLI installer
.github/workflows/
  ci.yml                          Local CI umbrella (pull_request)
  ci-*.yml                        Reusable pre-merge CI gates
  cd.yml                          Local CD umbrella (push to main/develop)
  cd-*.yml                        Reusable post-merge delivery
docs/site/                        MkDocs documentation source
```

## Branching and releases

- `develop` is the integration branch.
- Release branches are named `release/<version>` (e.g., `release/1.4.1`).
- Releases are tagged on `main` after the release PR merges.

## Versioning

- Repository-level SemVer tags (for example, `v1`, `v1.2.0`).
- Consumers must pin actions by tag or commit SHA.

## Documentation

Full documentation is available at
<https://vergil-project.github.io/vergil-actions/>.

## Validation

```bash
vrg-docker-run -- vrg-validate
```
