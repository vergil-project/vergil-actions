# Repository Rulesets

## Overview

All managed repositories use GitHub's **repository rulesets** (not legacy branch
protection rules) to enforce merge requirements. Every repository has the same
five rulesets, as vergil-tooling's desired state defines them (see its
[config audit reference](https://vergil-project.github.io/vergil-tooling/latest/reference/config-audit/#github-checks-rulesets)):

| Ruleset | Target | Purpose |
| --------- | -------- | --------- |
| Branch protection | `main`, `develop` | PR requirements, deletion and force-push prevention |
| CI gates | `main`, `develop` | Required status checks |
| Tag protection | `v*.*.*` and `v*.*` tags | Protect release tags and rolling minor tags |
| Rolling tag branch names | `refs/heads/v[0-9]*` | Block branches named like a rolling tag |
| Automation branches | `refs/heads/automation/**` | Only the org automation App and the repository Admin role may create, update or force-push these branches |

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
quality / evidence
security / trivy
security / semgrep
docs / docs
Trivy
Semgrep OSS
security / codeql
CodeQL
audit / evidence
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
audit or test evidence gates. It requires only the always-required checks
(including `quality / evidence`), the docs gate, the Trivy and Semgrep code
scanning checks, and the version gate:

```text
quality / evidence
security / trivy
security / semgrep
docs / docs
Trivy
Semgrep OSS
version / version-bump
```

Shell linting (shellcheck, actionlint and the other common linters) runs
inside `quality / common`, which is not required on its own: it gates the
merge through `quality / evidence`, as does `quality / custom`.

## Tag protection ruleset

Applies to the full semver release tags (such as `v1.1.1` or `v2.0.0`) and to
the rolling minor tags (such as `v1.1`) that consumers follow as their deploy
ref. Only the repository Admin role may move or delete either.

| Setting | Value |
| --------- | ------- |
| Patterns | `refs/tags/v*.*.*`, `refs/tags/v*.*` |
| Block deletion | Yes |
| Block non-fast-forward | Yes |
| Block update | Yes |
| Bypass actors | Repository Admin role (`RepositoryRole`, `actor_id: 5`, `bypass_mode: always`) |

### Why both `v*.*.*` and `v*.*`

A rolling minor tag (e.g., `v1.1`) always points to the latest patch release,
and consumers reference it to receive patch updates automatically. A consumer
that follows `v1.1` runs whatever the tag points to, so moving it is as
sensitive as moving a release tag. `v*.*.*` covers the immutable release tags
(`v1.1.1`, `v1.1.2`); `v*.*` covers the rolling tags. The publish workflow's
`tag-and-release` action no longer moves rolling tags: `vrg-promote` moves
them in the release orchestrator's `promote` phase (see
[`cd/release/tag-and-release`](../actions/cd-release-tag-and-release.md)).

### Admin bypass

The repository Admin role is the ruleset's only bypass actor. It is the human
release identity, so moving a rolling tag to a new patch release and cleanup
operations (e.g., removing a tag created against the wrong branch) both run
under it. No other identity, the agent Apps and the automation App included,
can move or delete a protected tag.

## Rolling tag branch names ruleset

Blocks any branch whose name has the shape of a rolling tag. Some consumers,
Claude Code among them, resolve a ref such as `v2.1` as a branch before a tag
(git's own short-name lookup prefers the tag), so for them the rolling tag's
protection holds only while no branch of that name can exist.

| Setting | Value |
| --------- | ------- |
| Pattern | `refs/heads/v[0-9]*` |
| Restrict creation | Yes |
| Restrict update | Yes |
| Block non-fast-forward | Yes |
| Bypass actors | None |

The pattern is a `v` followed by a digit, so names such as `vm-…` stay
available. Deletion is not restricted, so a stray branch of that shape can
still be removed.

## Automation branches ruleset

Mechanized jobs, such as the nightly `github-config` job, push to
`automation/<job>/<run-id>` branches and open a PR that merges through GitHub
auto-merge with no human in the loop. Without this ruleset any identity with
Contents write, every agent App included, could push to such a branch and have
its content merged into `develop`.

| Setting | Value |
| --------- | ------- |
| Pattern | `refs/heads/automation/**` |
| Restrict creation | Yes |
| Restrict update | Yes |
| Block non-fast-forward | Yes |
| Bypass actors | The org automation App (`Integration`, its per-org App ID, `bypass_mode: always`) and the repository Admin role (`RepositoryRole`, `actor_id: 5`, `bypass_mode: always`) |

Deletion is not restricted: automation branches are temporary, removed by
delete-on-merge and by each run of their job. The App's numeric ID differs per
org; `vrg-github-repo-config` looks it up from the App's slug in the
`VRG_AUTOMATION_APP` Actions variable.

## Adding a new required check

When adding a new CI job that should block merges:

1. Add the job to the CI workflow.
2. Open a PR and verify the check runs and passes.
3. Do not add the check by hand under **Settings > Rules**.
   `vrg-github-repo-config` derives the required-check set itself (from
   `desired_ci_gates_ruleset()` in vergil-tooling and the repository's
   `vergil.toml`), and the nightly `ops-github-config` run of
   `vrg-github-repo-config update` converges the ruleset back to that set,
   removing a hand-added check. Add the check to that derivation in
   vergil-tooling; once that change is released, the next nightly run (or
   `vrg-github-repo-config update` run by hand) converges the ruleset.
4. Verify the check name matches exactly. For the matrixed workflows, require
   the stable `<kind> / evidence` aggregate (e.g. `test / evidence`), **not** the
   per-version legs — the legs change with the resolved version set (the
   window or the `[ci].versions` pin), the aggregate does not.

## Branch targeting

The rulesets that protect `main` and `develop` use explicit branch references
(`refs/heads/main`, `refs/heads/develop`). **Never use `~DEFAULT_BRANCH`** in
ruleset conditions.

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

# Report the GitHub configuration differences only. Exit 0 whether or not
# there is drift; 2 = it could not complete or a setting is not checked.
vrg-github-repo-config diff --repo vergil-project/{repo}

# Reconcile the GitHub configuration, including the rulesets, and open one
# sync PR for any drifted managed file
vrg-github-repo-config update --repo vergil-project/{repo}
```

`--repo` defaults to the current directory's git remote. The local file
checks run against a fresh clone of the repository's `develop`, never the
current directory. `vergil.toml` is read from the `develop` branch;
`--config PATH` uses a local copy instead. `apply`, which reconciles only the
GitHub configuration, is deprecated in favour of `update`.

To change a ruleset, change the `vergil.toml` that it is derived from and
merge the change to `develop`; the nightly `ops-github-config` run of
`update` converges the ruleset, or run `update` by hand. A ruleset edited by
hand is converged back by that nightly run. See the vergil-tooling
[GitHub config audit reference](https://vergil-project.github.io/vergil-tooling/latest/reference/config-audit/)
for the full list of checks.
