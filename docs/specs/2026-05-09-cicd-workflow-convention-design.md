# CI/CD workflow convention

**Issue:** [#383](https://github.com/wphillipmoore/standard-actions/issues/383)
(incorporates [#387](https://github.com/wphillipmoore/standard-actions/issues/387))
**Date:** 2026-05-09
**Status:** Design
**Milestone:** v1.5

## Context

All workflow files live in the flat `.github/workflows/` directory. Two
problems exist today:

1. **Naming:** The current `publish-*` naming makes it hard to tell at
   a glance which files are reusable workflows consumed by the fleet and
   which are local to the repository. The files need a naming convention
   that communicates their role.

2. **Formatting:** The fleet's `ci.yml` files have diverged in format,
   organization, and commenting style. Job ordering, comment conventions,
   `workflow_call` input naming, and yamllint pragma usage vary from repo
   to repo.

Both problems are solved in a single coordinated fleet-wide rollout.

## Fleet (In Scope)

| # | Repo | Language | Integration Tests |
|---|---|---|---|
| 1 | standard-actions | shell | no |
| 2 | standard-tooling | python | no |
| 3 | standard-tooling-docker | shell | no |
| 4 | standard-tooling-plugin | claude-plugin | no |
| 5 | mq-rest-admin-python | python | yes |
| 6 | mq-rest-admin-go | go | yes |
| 7 | mq-rest-admin-ruby | ruby | yes |
| 8 | mq-rest-admin-java | java | yes |
| 9 | mq-rest-admin-rust | rust | yes |
| 10 | mq-rest-admin-common | shell | no |
| 11 | mq-rest-admin-dev-environment | shell | no |
| 12 | ai-research-methodology | python | no |

## Out of Scope

- Integration test job internals — left bespoke per repo.
- Reusable workflow internals (`ci-quality.yml`, `cd-release.yml`, etc.)
  — their formatting will be addressed but their logic is unchanged.

---

## Part 1: Naming Convention

### CI/CD namespace pattern

| Pattern | Role | Trigger |
|---|---|---|
| `ci.yml` | Local umbrella | `pull_request` |
| `ci-*.yml` | Reusable pre-merge gate | `workflow_call` |
| `cd.yml` | Local umbrella | `push` to main/develop |
| `cd-*.yml` | Reusable post-merge delivery | `workflow_call` |

**Bare category name** (`ci.yml`, `cd.yml`) = local consumer entry
point. **Category-subcategory** (`ci-quality.yml`, `cd-release.yml`) =
reusable workflow shared across the fleet.

### Consumer repo model

Each consumer repo has at most two workflow files:

- `ci.yml` — thin umbrella calling the `ci-*` reusable workflows
- `cd.yml` — thin umbrella calling the `cd-*` reusable workflows

Additional repo-specific workflow files are permitted but should be rare
(e.g., `docker-publish.yml` in standard-tooling-docker).

### standard-actions file renames

| Current | New | Notes |
|---|---|---|
| `ci-release.yml` | `ci-version-bump.yml` | Reflects what it checks |
| `publish-release.yml` | `cd-release.yml` | CI/CD namespace |
| `publish-docs.yml` | `cd-docs.yml` | workflow_call only (split) |
| `publish.yml` | `cd.yml` | Local umbrella |

Unchanged: `ci.yml`, `ci-quality.yml`, `ci-security.yml`, `ci-test.yml`,
`ci-audit.yml`.

### `cd.yml` (local umbrella)

Replaces `publish.yml`. Absorbs the push triggers from `publish-docs.yml`.
Calls both `cd-release.yml` (push to main) and `cd-docs.yml` (push to
develop/main).

### `cd-docs.yml` (split from `publish-docs.yml`)

Becomes workflow_call-only. The push trigger moves into `cd.yml`.

### Workflow `name:` fields

| File | `name:` field |
|---|---|
| `ci-version-bump.yml` | `CI Version Bump` |
| `cd-release.yml` | `CD Release` |
| `cd-docs.yml` | `CD Docs` |
| `cd.yml` | `CD` |

### Check name changes

#### CI gates (enforced via branch protection)

| Current | New |
|---|---|
| `release / version-bump` | `version / version-bump` |

All other CI gate check names are unchanged.

The change is caused by the `ci.yml` caller job key changing from
`release` to `version`. The inner job name (`version-bump`) is unchanged.

#### CD checks (informational, not enforced)

| Workflow | Check name |
|---|---|
| `cd-release.yml` | `release / release` |
| `cd-docs.yml` | `cd / docs` |

---

## Part 2: Formatting Convention

### Formatting Rules

These rules apply to all workflow YAML files across the fleet.

#### File-level structure (top to bottom)

1. Reference comment (URL to the README — consumer repos only)
2. `name:`
3. `on:` (trigger configuration)
4. `permissions:` (if needed at workflow level)
5. `concurrency:` (if needed)
6. `jobs:` — entries in **alphabetical order** by job key

#### Job ordering

Alphabetical by job key. Always. No exceptions. This removes all
judgment calls about "logical grouping." GitHub Actions runs jobs in
parallel by default, so file order is purely organizational.

#### Comments

- No section banners or decorative separators.
- No redundant labels (a comment that restates the job key is pointless).
- Comments only when the YAML itself does not convey the intent — e.g.,
  a workaround, a non-obvious constraint, or a known issue.
- No `# yamllint disable-line` pragmas. Fix the YAML instead.

#### Whitespace

- One blank line between top-level keys (`on:`, `permissions:`,
  `concurrency:`, `jobs:`).
- One blank line between jobs within the `jobs:` block.
- No trailing blank lines at end of file.

### Standardized `workflow_call` Inputs

#### Toggle inputs

All boolean toggle inputs use `type: boolean` (not `type: string`):

- `run-security` — `type: boolean`, `default: true`
- `run-release` — `type: boolean`, `default: true`

#### Version matrix input

Always named `versions` (not language-prefixed like `go-versions` or
`ruby-versions`). Uses `type: string` since GitHub Actions does not
support array-typed inputs. Repos without a version matrix omit this
input.

### Bespoke Jobs

Some repos have jobs not from standard-actions' reusable workflows:

- **standard-tooling-docker** — `hadolint` (Dockerfile linting)
- **standard-tooling-plugin** — `mkdocs-build` (docs build check)
- **mq-rest-admin-rust** — custom `test` job with coverage thresholds

Bespoke jobs follow the same formatting rules. They sort alphabetically
alongside everything else. If a bespoke job replaces a standard reusable
workflow, it keeps the same job key.

### Reference Comment

Every consuming repo's workflow files include a single comment on line 1:

```yaml
# https://github.com/wphillipmoore/standard-actions/blob/develop/.github/workflows/README.md
name: CI
```

Rules:
- Line 1, always — before `name:`.
- Just the raw URL, no surrounding prose.
- Points to the `develop` branch.
- standard-actions' own workflow files skip this (README is co-located).

### Deliverable: `.github/workflows/README.md`

A canonical document in standard-actions at `.github/workflows/README.md`
serving as both the convention specification and reference implementation.
Contains formatting rules, the reference comment convention, and
complete copy-pasteable examples for each fleet archetype.

---

## Part 3: standard-tooling Changes

### Check name registry

In `src/standard_tooling/lib/github_config.py`, the
`desired_ci_gates_ruleset()` function updates `release / version-bump`
to `version / version-bump`.

### standard-tooling's own workflows

| Current | New |
|---|---|
| `.github/workflows/publish-release.yml` | `.github/workflows/cd-release.yml` |
| `.github/workflows/publish-docs.yml` | `.github/workflows/cd-docs.yml` |
| `.github/workflows/ci.yml` | Updated (job key + formatting) |

The two publish callers merge into a single `cd.yml`. The `ci.yml` gets
the job key rename (`release` → `version`) and formatting standardization
(alphabetical ordering, no banners).

---

## Part 4: Per-Repo Changes

### standard-actions

- Create `.github/workflows/README.md` with convention and examples.
- Rename workflows per Part 1.
- Reformat `ci.yml`: alphabetical job ordering, no banners.

### standard-tooling

- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reformat `ci.yml`: add reference comment, remove banners, reorder
  alphabetically (audit, quality, release→version, security, test).
- Fix toggle input types if needed.

### standard-tooling-docker

- Add reference comment.
- Remove banner comments.
- Rename `release` job key to `version`, update `uses:` path.
- Merge `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically (hadolint, quality, security, version).

### standard-tooling-plugin

- Add reference comment.
- Remove banner comments.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically (mkdocs-build, quality, security, version).

### mq-rest-admin-python

- Add reference comment.
- Remove banner comments.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically (audit, integration-tests, quality,
  security, test, version).

### mq-rest-admin-go

- Add reference comment.
- Rename `go-versions` input to `versions`.
- Change `run-security`/`run-release` from `type: string` to `boolean`.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically.

### mq-rest-admin-ruby

- Add reference comment.
- Rename `ruby-versions` input to `versions`.
- Change `run-security`/`run-release` from `type: string` to `boolean`.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically.

### mq-rest-admin-java

- Add reference comment.
- Rename `java-versions` input to `versions`.
- Remove all `# yamllint disable-line` pragmas.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically.

### mq-rest-admin-rust

- Add reference comment.
- Rename `rust-versions` input to `versions`.
- Change `run-security`/`run-release` from `type: string` to `boolean`.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically.

### mq-rest-admin-common

- Add reference comment.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically (quality, security, version).

### mq-rest-admin-dev-environment

- Add reference comment.
- Remove banner comments.
- Rename `release` → `version`, update `uses:` path.
- Merge `publish-release.yml` + `publish-docs.yml` → `cd.yml`.
- Reorder jobs alphabetically (quality, security, version).

### ai-research-methodology

- Add reference comment.
- Remove banner comments.
- Rename `release` → `version`, update `uses:` path.
- Create `cd.yml` (release only, no docs).
- Delete `publish-release.yml`.
- Reorder jobs alphabetically (audit, quality, security, test, version).

---

## Part 5: Rollout Strategy

Approach: big-bang with scripted rollout.

### Sequence

1. **standard-tooling code changes** — update check name registry,
   release new version. Prerequisite for everything else.
2. **standard-actions ships renamed + reformatted workflows** — v1.5.x
   release with file renames, formatting, and README.
3. **Fleet sweep** — rollout script generates one PR per consumer repo
   containing all naming + formatting changes.

### Rollout script

The script takes a repo name (or "all") and mechanically:

- Renames workflow files (publish-* → cd-*, ci-release → ci-version-bump)
- Rewrites `ci.yml` with correct formatting (alphabetical, no banners,
  reference comment, standardized inputs)
- Creates `cd.yml` umbrella from publish callers
- Updates branch protection rules via `st-github-config sync`
- Creates a PR

### Manual scope

- standard-tooling Python code changes (check name registry)
- README authoring in standard-actions
- Deployment race condition handling between releases

Deployment race conditions between standard-tooling and standard-actions
may require temporary manual branch protection adjustments. Acceptable
at fleet scale of one maintainer.

---

## Notes

### standard-tooling-docker special case

`docker-publish.yml` is repo-specific and stays as-is. The rollout
script only touches standard-actions-backed workflows.

### `PublishConfig` class naming

`PublishConfig` / `DesiredPublishConfig` classes and the `[publish]`
TOML section are not renamed. They hold boolean flags, not workflow
filenames. Renaming to `CdConfig` / `[cd]` is a clean follow-up but
not required.

### Superseded specs

This spec supersedes:
- `docs/specs/2026-05-09-cicd-namespace-convention-design.md` (#383)
- `docs/specs/2026-05-09-ci-yaml-standardization-design.md` (#387)

Both are removed from the repository as part of this change.
