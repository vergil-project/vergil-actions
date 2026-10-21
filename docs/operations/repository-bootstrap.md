# Repository bootstrap (standards framework)

## Table of Contents

- [Purpose](#purpose)
- [Prerequisites](#prerequisites)
- [Required files](#required-files)
- [AGENTS.md template](#agentsmd-template)
- [Standards entrypoint](#standards-entrypoint)
- [Repository profile](#repository-profile)
- [Validation](#validation)
- [Follow-up tasks](#follow-up-tasks)

## Purpose

Define the minimum, repeatable steps to bootstrap a repository that follows the
standards-and-conventions framework.

## Prerequisites

- Access to the standards-and-conventions repository.
- Agreement on repository type and release model.

## Required files

- `AGENTS.md`
- `docs/standards-and-conventions.md`
- `vergil.toml`

## AGENTS.md template

Use includes and keep local overrides explicit.

```text
# <Repository> Agent Instructions

**Standards reference**: <https://github.com/wphillipmoore/standards-and-conventions>
— active standards documentation lives in the vergil-tooling repository under `docs/`.
Repository profile: `vergil.toml`.

## User Overrides (Optional)

If `~/AGENTS.md` exists and is readable, load it and apply it as a
user-specific overlay for this session. If it cannot be read, say so
briefly and continue.

## Canonical Standards

This repository follows the canonical standards and conventions in the
`standards-and-conventions` repository.

Resolve the local path (preferred):
- `../standards-and-conventions`

If the local path is unavailable, use the canonical web source:
- https://github.com/wphillipmoore/standards-and-conventions

If the canonical standards cannot be retrieved, treat it as a fatal
exception and stop.

## Shared Skills

Replace `<standards-repo-path>` with the resolved local path when available.
- Load all skills from: `<standards-repo-path>/skills/**/SKILL.md`
- Treat every skill found under that directory as available and active.

## Local Overrides

None.
```

## Standards entrypoint

`docs/standards-and-conventions.md` must reference the canonical standards and
avoid duplicating project-specific content. Use a simple link list or the
include chain pattern described in the canonical standards.

## Repository profile

The repository profile lives in `vergil.toml` under `[project]`.
Required fields: `repository-type`, `versioning-scheme`, `branching-model`,
`release-model`, `primary-language`. Commits carry no AI co-author
trailer; Claude Code attribution is turned off in `.claude/settings.json`
(vergil-project/vergil-tooling#3200).

Local deviations, if any, belong directly in `CLAUDE.md`.

## Validation

- Run the repository’s canonical validation command.
- Fix markdownlint failures before submitting a PR.

## Follow-up tasks

- Add a bootstrap log entry if the repository tracks operational history.
- Document any local tooling requirements.
