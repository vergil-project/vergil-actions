# Vergil Actions

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
  cd/docs/deploy/                 MkDocs + mike versioned deployment
  cd/release/                     Release inputs, tagging, registry publish,
                                  CI evidence gate and attach
  ci/evidence/emit/               Per-gate CI evidence artifact
  ci/matrix/                      Per-version job matrix from vrg-ci-resolve
  ci/security/                    CodeQL and Semgrep scanning
  ci/toolchain/                   Pin (pin-python) and assert the leg toolchain
  ci/version-bump/                Pre-merge version divergence gate
  local/freeze-internal-refs/     Freeze relative action refs at release
  ops/github-config/              Branch sweep for ops-github-config
  package/setup/                  Binary package build setup
  shared/docs/stage/              Changelog/release-notes pages for docs
  shared/security/trivy/          Trivy scanning
  shared/setup/                   vergil-tooling install and version resolve,
                                  system packages, build command
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
vrg-container-run -- vrg-validate
```
