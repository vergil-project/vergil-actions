# Repository Rulesets

## Overview

All managed repositories use GitHub's **repository rulesets** (not legacy branch
protection rules) to enforce merge requirements. Every repository has the same
three rulesets:

| Ruleset | Target | Purpose |
| --------- | -------- | --------- |
| Branch protection | `main`, `develop` | PR requirements, deletion and force-push prevention |
| CI gates | `main`, `develop` | Required status checks |
| Tag protection | `v*.*.*` tags | Protect semver release tags; allow rolling minor tags |

## Branch protection ruleset

Applies to both `main` and `develop` branches across all repositories.

| Setting | Value |
| --------- | ------- |
| Require pull request | Yes |
| Required approving review count | 0 |
| Dismiss stale reviews on push | Yes |
| Require code owner review | No |
| Require last push approval | No |
| Require review thread resolution | No |
| Allowed merge methods | merge, squash, rebase |
| Block deletion | Yes |
| Block non-fast-forward | Yes |
| Bypass actors | None (`current_user_can_bypass: never`) |

!!! note "Zero required approvals"
    The required approving review count is set to 0. PRs still require a pull
    request (direct pushes are blocked), but self-approval is permitted. This is
    appropriate for single-maintainer repositories.

## CI gates ruleset

Applies to both `main` and `develop` branches. Contains the required status
checks that must pass before a PR can merge.

| Setting | Value |
| --------- | ------- |
| Strict required status checks | Yes (branch must be up to date) |
| Do not enforce on create | No |

`vrg-github-repo-config` derives the required checks from each repository's
`vergil.toml`, so the set depends on the repository's configuration. See the
[required check set](required-checks.md#required-check-set) for the full list
and the condition under which each check is required.

### Example: a public Python library

A public Python library that publishes docs and has a release model gets:

```text
quality / common
security / trivy
security / semgrep
docs / docs
Trivy
Semgrep OSS
security / codeql
CodeQL
audit / evidence
quality / evidence
test / evidence
version / version-bump
```

`Trivy`, `Semgrep OSS` and `CodeQL` are GitHub code scanning checks, required
because GHAS is available on a public repository. A repository with a
`[package]` section also requires `package / evidence`.

!!! note "Version-agnostic evidence gates"
    The matrixed workflows (`ci-audit`, `ci-quality`, `ci-test`) take their
    version matrix from `vrg-ci-resolve`, which resolves `vergil.toml` against
    the published language version window, so the per-version legs
    (`unit / 3.14`, `lint / 3.13`, …) change whenever the resolved set
    changes: the window gains or drops a version, or the `[ci].versions` pin
    changes. Branch
    protection therefore requires the stable `<kind> / evidence` **aggregate**
    gates — `audit / evidence`, `quality / evidence`, `test / evidence` — not
    the per-version legs. Each evidence job runs with `if: always()` and
    asserts every leg succeeded, so a failed or skipped leg fails the aggregate
    red. A change to the resolved set changes the legs but not the
    required-check set. See
    [Evidence gates are the required checks](required-checks.md#evidence-gates-are-the-required-checks).

### Example: vergil-actions

This repository declares no primary language in `vergil.toml` (its `ci.yml`
passes `language: shell` to the workflows), so it gets no CodeQL checks and no
audit, quality or test evidence gates. It requires only the always-required
checks, the docs gate, the Trivy and Semgrep code scanning checks, and the
version gate:

```text
quality / common
security / trivy
security / semgrep
docs / docs
Trivy
Semgrep OSS
version / version-bump
```

Shell linting (shellcheck, actionlint and the other common linters) runs
inside `quality / common`.

## Tag protection ruleset

Applies to all tags matching `v*.*.*` (full semver tags such as `v1.1.1` or
`v2.0.0`). Prevents unauthorized modification of release tags while allowing
the publish workflow to create and update rolling minor tags (e.g., `v1.1`).

| Setting | Value |
| --------- | ------- |
| Pattern | `refs/tags/v*.*.*` |
| Block deletion | Yes |
| Block non-fast-forward | Yes |
| Block update | Yes |
| Bypass actors | Repository admin (`actor_id: 5`, `bypass_mode: always`) |

### Why `v*.*.*` instead of `v*`

The publish workflow's `tag-and-release` action creates a rolling minor tag
(e.g., `v1.1`) that always points to the latest patch release. Consumers
reference these rolling tags to receive automatic patch updates. The broader
`v*` pattern matches both `v1.1.1` (semver) and `v1.1` (rolling), which causes
the rolling tag force-push to fail with a repository rule violation.

The `v*.*.*` pattern requires three dot-separated components, so it protects
immutable release tags (`v1.1.1`, `v1.1.2`) while leaving rolling tags (`v1.1`)
unprotected for the workflow to update.

### Admin bypass

The repository admin bypass exists as a safety valve for cleanup operations
(e.g., removing a tag created against the wrong branch). Normal publish
operations do not require admin bypass — the rolling tag update succeeds because
rolling tags fall outside the `v*.*.*` pattern.

## Adding a new required check

When adding a new CI job that should block merges:

1. Add the job to the CI workflow.
2. Open a PR and verify the check runs and passes.
3. Do not add the check by hand under **Settings > Rules**.
   `vrg-github-repo-config` derives the required-check set itself (from
   `desired_ci_gates_ruleset()` in vergil-tooling and the repository's
   `vergil.toml`), and the nightly `ops-github-config` audit reports a
   hand-added check as drift. Add the check to that derivation in
   vergil-tooling, and once that change is released run
   `vrg-github-repo-config apply` to converge the ruleset.
4. Verify the check name matches exactly. For the matrixed workflows, require
   the stable `<kind> / evidence` aggregate (e.g. `test / evidence`), **not** the
   per-version legs — the legs change with the resolved version set (the
   window or the `[ci].versions` pin), the aggregate does not.

## Branch targeting

All rulesets use explicit branch references (`refs/heads/main`,
`refs/heads/develop`). **Never use `~DEFAULT_BRANCH`** in ruleset conditions.

The `~DEFAULT_BRANCH` macro resolves to the repository's configured default
branch. In this project family, the default branch is `develop` (not `main`),
so `~DEFAULT_BRANCH` resolves to `develop` — silently leaving `main`
unprotected. Always use explicit `refs/heads/` references for both branches.

## Modifying rulesets via API

Do not edit rulesets with raw `gh api` calls. `vrg-github-repo-config`
computes the desired rulesets from the repository's `vergil.toml` and converges
GitHub to them through the API:

```bash
# Report drift in the local files and the GitHub configuration.
# Exit 0 = compliant, 1 = drift, 2 = the audit could not complete.
vrg-github-repo-config audit --repo vergil-project/{repo}

# Show the same differences without failing (always exits 0)
vrg-github-repo-config diff --repo vergil-project/{repo}

# Reconcile the GitHub configuration, including the rulesets
vrg-github-repo-config apply --repo vergil-project/{repo}
```

`--repo` defaults to the current directory's git remote. The local file
checks run only from inside the repository's own checkout. `vergil.toml` is
read from the `develop` branch; `--config PATH` uses a local copy instead.

To change a ruleset, change the `vergil.toml` that it is derived from, merge the
change to `develop`, and run `apply`. A ruleset edited by hand is reported as
drift by the nightly `ops-github-config` audit. See the vergil-tooling
[GitHub config audit reference](https://vergil-project.github.io/vergil-tooling/latest/reference/config-audit/)
for the full list of checks.
