# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Project Overview

vergil-actions is the shared GitHub Actions library for every managed
repository: composite actions under `actions/` and reusable CI/CD workflows
under `.github/workflows/`, consumed through `workflow_call` and `uses:` pinned
to a release tag (for example `@v2.1`). Repository profile: `vergil.toml`.

- Environment setup:
  [`docs/site/docs/development/environment-and-tooling.md`](docs/site/docs/development/environment-and-tooling.md).
- Action reference: [`docs/site/docs/actions/index.md`](docs/site/docs/actions/index.md).
- Workflow reference: [`docs/site/docs/workflows/index.md`](docs/site/docs/workflows/index.md).

## Action layout

The `actions/` directory mirrors the workflow namespace. To find an action,
take the workflow filename (e.g., `ci-security.yml`), split on the first `-` to
get phase and domain (`ci` / `security`), and look in
`actions/{phase}/{domain}/`. Cross-phase actions live in `actions/shared/`.
Repo-local actions live in `actions/local/`. Exceptions: `ci-package.yml`
uses `actions/package/setup`, and `actions/ci/matrix`, `actions/ci/toolchain/*`
and `actions/ci/evidence/emit` are shared building blocks with no matching
workflow.

## Self-Referencing CI

This repository's CI workflow uses **local paths** (`./actions/...`)
rather than remote references. This enables self-testing: changes to an
action are validated by the same PR that modifies them. At release,
`actions/local/freeze-internal-refs` rewrites those internal refs to absolute
refs at the release tag.

<!-- vergil:template:claude-md:begin -->
## Memory

Never write, edit or delete memory files without explicit human approval.
Propose the entry and where it belongs first, then wait for the decision.

## Worktrees

- Sessions always start at the project root, never inside `.worktrees/`.
- One worktree per issue: `.worktrees/issue-<N>-<slug>/` on branch
  `feature/<N>-<slug>`. Remove it once its branch lands.
- The main worktree is read-only, bar ignored `build/` scratch; every edit goes through a worktree.
- Read, Edit and Write use the worktree's absolute path. Bash commands `cd`
  into the worktree first or use absolute paths.
- The full convention: <https://github.com/vergil-project/vergil-tooling/blob/develop/docs/specs/worktree-convention.md>.
- Brief each parallel sub-agent with its [Agent prompt contract](https://github.com/vergil-project/vergil-tooling/blob/develop/docs/specs/worktree-convention.md#agent-prompt-contract).

## Git and GitHub

Use `vrg-git` and `vrg-gh` only; the hook guard blocks raw `git` and `gh`. If a
command is not available through the wrappers, explain why and ask the human to
run it with `! <command>` in the prompt.

## Validation

`vrg-container-run -- vrg-validate` is the only validation command. Don't run
linters, formatters or tests outside it; a tool it doesn't invoke is not part
of the pipeline.

## PR handoff

- Agents never run `vrg-submit-pr`. Submitting, merging and finalizing a PR are
  human actions.
- Hand off with `vrg-pr-workflow report-ready --issue <N> --title --summary
  --notes`. It pushes the branch itself. Leave `--linkage` at its default (`Ref`).
- A delta touching `.github/workflows/**` makes GitHub refuse the agent push.
  That is expected: report-ready records the state anyway and the human's
  `vrg-submit-pr` pushes the branch.
- After report-ready the branch is frozen: no new commits and no push that
  advances it; more work is a new follow-up issue. Re-running report-ready to
  fix the prose is allowed. `vrg-pr-workflow unfreeze` is the only way to lift it.
- The report-ready title, summary and notes are public (the relay ref is
  world-readable): never put secrets in them.

## Local settings

`.claude/settings.local.json` must stay absent or exactly `{}`; the agent tools
refuse otherwise. See the [ownership model](https://github.com/vergil-project/vergil-tooling/blob/develop/docs/site/docs/guides/claude-config-ownership.md).

## Engineering principles

- Correctness over cost over speed. Never ship known-broken code with a
  follow-up fix; if something is wrong, fix it now.
- No silent failures: no swallowed exceptions, no `except: return ""`, no
  fallbacks that hide errors. A failure hidden in code becomes a hallucination
  at the AI layer.

## paad

paad usage policy and deviations:
<https://github.com/vergil-project/vergil-claude-plugin/blob/develop/docs/paad-policy.md>.
<!-- vergil:template:claude-md:end -->
