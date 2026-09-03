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

The required checks vary by repository category. See the
[check matrix](required-checks.md#check-matrix) for the full list.

### Library repositories (Go, Python, Ruby, Java)

```text
ci: standards-compliance
audit / evidence
quality / evidence
test / evidence
release: gates
security: codeql
security: semgrep
security: trivy
```

!!! note "Version-agnostic evidence gates"
    The matrixed workflows (`ci-audit`, `ci-quality`, `ci-test`) derive their
    version matrix from `[ci].versions` in `vergil.toml`, so the per-version
    legs (`unit / 3.14`, `lint / 3.13`, …) change with that set. Branch
    protection therefore requires the stable `<kind> / evidence` **aggregate**
    gates — `audit / evidence`, `quality / evidence`, `test / evidence` — not
    the per-version legs. Each evidence job runs with `if: always()` and
    asserts every leg succeeded, so a failed or skipped leg fails the aggregate
    red. Adding or dropping a version in `[ci].versions` changes the legs but
    not the required-check set. See
    [Evidence gates are the required checks](required-checks.md#evidence-gates-are-the-required-checks).

### Infrastructure repositories

```text
ci: standards-compliance
ci: shellcheck
```

The vergil-actions repository additionally requires `ci: actionlint`.

### Documentation repositories

```text
ci: standards-compliance
```

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

1. Add the job to the CI workflow with the appropriate
   [name prefix](required-checks.md#job-name-prefix-convention).
2. Open a PR and verify the check runs and passes.
3. After the PR merges, add the exact check name to the CI gates ruleset via
   **Settings > Rules > Rulesets > CI gates**.
4. Verify the check name matches exactly. For the matrixed workflows, require
   the stable `<kind> / evidence` aggregate (e.g. `test / evidence`), **not** the
   per-version legs — the legs change with `[ci].versions`, the aggregate does
   not.

## Branch targeting

All rulesets use explicit branch references (`refs/heads/main`,
`refs/heads/develop`). **Never use `~DEFAULT_BRANCH`** in ruleset conditions.

The `~DEFAULT_BRANCH` macro resolves to the repository's configured default
branch. In this project family, the default branch is `develop` (not `main`),
so `~DEFAULT_BRANCH` resolves to `develop` — silently leaving `main`
unprotected. Always use explicit `refs/heads/` references for both branches.

## Modifying rulesets via API

Rulesets can be updated programmatically using the GitHub API:

```bash
# List rulesets for a repository
gh api repos/vergil-project/{repo}/rulesets \
  --jq '.[] | {id: .id, name: .name}'

# View a specific ruleset
gh api repos/vergil-project/{repo}/rulesets/{id}

# Update required status checks
gh api --method PUT repos/vergil-project/{repo}/rulesets/{id} \
  --input payload.json
```
