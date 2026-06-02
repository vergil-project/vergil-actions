# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

**Standards reference**: <https://github.com/wphillipmoore/standards-and-conventions>
— active standards documentation lives in the vergil-tooling repository under `docs/`.
Repository profile: `vergil.toml`.

## Memory management

Memory is allowed with human approval. The authoritative policy is in
the user's global `~/.claude/CLAUDE.md` — agents must propose memory
writes and suggest a destination (repo memory, global CLAUDE.md, or
plugin/skill issue) before writing. See that file for the full
workflow.

Available skills:
- `/vergil:memory-init` — set up or update the policy header
  in a project's `MEMORY.md`.
- `/vergil:memory-audit` — structured collaborative review
  of memory files.

## Parallel AI agent development

This repository supports running multiple Claude Code agents in parallel via
git worktrees. The convention keeps parallel agents' working trees isolated
while preserving shared project memory (which Claude Code derives from the
session's starting CWD).

**Canonical spec:**
[`vergil-tooling/docs/specs/worktree-convention.md`](https://github.com/vergil-project/vergil-tooling/blob/develop/docs/specs/worktree-convention.md)
— full rationale, trust model, failure modes, and memory-path implications.
The canonical text lives in `vergil-tooling`; this section is the local
on-ramp.

### Structure

```text
<project-root>/                              ← sessions ALWAYS start here
  .git/
  CLAUDE.md, …                               ← main worktree (usually `develop`)
  .worktrees/                                ← container for parallel worktrees
    issue-<N>-<short-slug>/                  ← worktree on feature/<N>-<short-slug>
    …
```

### Rules

1. **Sessions always start at the project root.**
   Never start Claude from inside `.worktrees/<name>/`. This keeps the
   memory-path slug stable and shared.
2. **Each parallel agent is assigned exactly one worktree.** The session
   prompt names the worktree (see Agent prompt contract below).
   - For Read / Edit / Write tools: use the worktree's absolute path.
   - For Bash commands that touch files: `cd` into the worktree first,
     or use absolute paths.
3. **The main worktree is read-only.** All edits flow through a worktree
   on a feature branch — the logical endpoint of the standing
   "no direct commits to develop" policy.
4. **One worktree per issue.** Don't stack in-flight issues. When a
   branch lands, remove the worktree before starting the next.
5. **Naming: `issue-<N>-<short-slug>`.** `<N>` is the GitHub issue
   number; `<short-slug>` is 2–4 kebab-case tokens.

### Agent prompt contract

When launching a parallel-agent session, use this template (fill in the
placeholders):

```text
You are working on issue #<N>: <issue title>.

Your worktree is: <project-root>/.worktrees/issue-<N>-<slug>/
Your branch is:   feature/<N>-<slug>

Rules for this session:
- Do all git operations from inside your worktree:
    cd <absolute-worktree-path> && vrg-git <command>
- For Read / Edit / Write tools, use the absolute worktree path.
- For Bash commands that touch files, cd into the worktree first
  or use absolute paths.
- Do not edit files at the project root. The main worktree is
  read-only — all changes flow through your worktree on your
  feature branch.
- When you need to run validation, run it from inside your worktree
  (vrg-container-run mounts the current directory).
```

All fields are required.

## Shell command policy

Use `vrg-git` instead of `git` for all git operations. Use `vrg-gh`
instead of `gh` for all GitHub CLI operations. These wrappers enforce
subcommand allowlists, flag deny lists, and credential selection.

Raw `git` and `gh` are denied by the permission model. If a command
is not available through the wrappers, explain the situation to the
human who can run it directly via `! <command>` in the prompt.

## Validation

```bash
vrg-container-run -- vrg-validate
```

This is the **only** validation command. Do not run individual linters,
formatters, or other tools outside of `vrg-validate`. If a tool is not
invoked by `vrg-validate`, it is not part of the validation pipeline.

## Project Overview

This is a shared GitHub Actions library providing reusable composite actions
for CI/CD across all managed repositories. Actions are consumed by pinning
to a tag or branch reference.

**Project name**: vergil-actions

**Status**: v1.x (stable)

**Canonical Standards**: This repository follows standards at
<https://github.com/wphillipmoore/standards-and-conventions>
(local path: `../standards-and-conventions` if available)

## Development Commands

### Environment Setup

Standard-tooling CLI tools (`vrg-commit`, `vrg-validate`, etc.) are
pre-installed in the dev container images. No local setup required beyond
the host-level tool (`vrg-docker-run`, `vrg-commit`, etc.):

```bash
uv tool install 'vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v1.4'
```

All validation tools (yamllint, shellcheck, actionlint, markdownlint, etc.)
run inside the `ghcr.io/vergil-project/dev-base:latest` container — no manual
host installs needed.

## Architecture

### Composite Actions

All actions live under `actions/` organized by pipeline phase:

**Convention:** The `actions/` directory mirrors the workflow namespace.
To find an action, take the workflow filename (e.g., `ci-security.yml`),
split on the first `-` to get phase and domain (`ci` / `security`), and
look in `actions/{phase}/{domain}/`. Cross-phase actions live in
`actions/shared/`. Repo-local actions live in `actions/local/`.

- `actions/ci/security/standards-compliance` — PR-specific compliance
  checks: issue linkage and auto-close keyword rejection
- `actions/ci/security/codeql` — CodeQL static analysis
- `actions/ci/security/semgrep` — Semgrep SAST scanning
- `actions/ci/version-bump/version-divergence` — Pre-merge version
  validation
- `actions/cd/release/validate-inputs` — Pre-flight release input
  validation
- `actions/cd/release/registry-publish` — Build and publish pipeline
  for any supported language ecosystem
- `actions/cd/release/tag-and-release` — Annotated git tags, changelog
  boundary tags, and GitHub Releases
- `actions/cd/docs/deploy` — MkDocs Material + mike versioned
  documentation deployment
- `actions/shared/docs/stage` — Stages changelog/release-notes pages and
  patches mkdocs nav; shared by CI docs verification and CD docs deploy
- `actions/shared/security/trivy` — Trivy vulnerability scanning
  (filesystem, SBOM, container image)
- `actions/shared/setup/vergil-tooling` — Installs vergil-tooling
  from the version pinned in `vergil.toml`
- `actions/local/freeze-internal-refs` — Freezes relative action refs
  to absolute tagged refs (repo-local)

### Reusable Workflows

CI and CD workflows live under `.github/workflows/` and are consumed via
`workflow_call`:

- `ci-docs.yml` — Build-only MkDocs strict verification (no deploy)
- `ci-quality.yml` — Common linting, language-specific lint and typecheck
- `ci-security.yml` — Standards compliance and security scanning
- `ci-test.yml` — Unit and integration tests
- `ci-audit.yml` — Dependency audit
- `ci-version-bump.yml` — Version divergence gate
- `cd-release.yml` — Full release pipeline (tag, build, publish, version
  bump)
- `cd-docs.yml` — MkDocs documentation deployment

### Self-Referencing CI

This repository's CI workflow uses **local paths** (`./actions/...`)
rather than remote references. This enables self-testing: changes to an
action are validated by the same PR that modifies them.

### Standard-Tooling Integration

Shared validators (`st-repo-profile`, `st-pr-issue-linkage`) and local
validation (`vrg-validate`) are provided by `vergil-tooling`. CI uses
the `ghcr.io/vergil-project/dev-base:latest` container image which has all
validators pre-installed. Locally, `vrg-docker-run` uses the same image so
validation results match CI exactly.
