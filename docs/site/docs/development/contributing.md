# Contributing

## Adding a new action

1. Create a directory under `actions/` following the namespace convention:
   `actions/{phase}/{domain}/{action}/action.yml`. The phase is one of:

    | Phase | Use for | Example |
    | ----- | ------- | ------- |
    | `ci` | Pre-merge checks, consumed by the `ci-*` workflows | `ci/security/codeql` |
    | `cd` | Post-merge release and deploy, consumed by the `cd-*` workflows | `cd/release/tag-and-release` |
    | `ops` | Scheduled repository maintenance, consumed by the `ops-*` workflows | `ops/github-config/branch-sweep` |
    | `package` | `.deb`/`.rpm` package builds, consumed by `ci-package` and `cd-release` | `package/setup` |
    | `shared` | Actions used by more than one phase | `shared/setup/vergil` |
    | `local` | Actions used only by this repository's own workflows | `local/freeze-internal-refs` |

    For `ci`, `cd` and `ops` the domain matches the workflow that consumes the
    action (`ci/security/*` for `ci-security.yml`, `ops/github-config/*` for
    `ops-github-config.yml`). An action used by several workflows in one phase
    takes a descriptive domain instead (`ci/evidence/emit`).

    Two actions sit directly under their phase, with no domain:
    `package/setup`, the only action in the `package` phase, and `ci/matrix`.
    New actions use the three-level layout.
2. Define the action as a **composite action** — no custom JavaScript or Docker
   actions.
3. Include clear `name`, `description`, `inputs`, and `outputs` in `action.yml`.
4. Put supporting scripts next to `action.yml` in the action directory (e.g.
   `actions/shared/setup/vergil/derive.sh`) and call them through
   `${GITHUB_ACTION_PATH}`. Put their tests in a `tests/` subdirectory.
5. Add the action to the appropriate workflow using a local path reference
   (`./actions/{phase}/{domain}/{action}`).
6. Add a documentation page under `docs/site/docs/actions/` and update the nav
   in `docs/site/mkdocs.yml`.

## Composite action design rules

- **Shell steps only** — Use `shell: bash` for all `run` steps.
- **No secrets access** — Composite actions cannot access secrets directly.
  Callers must pass secrets as inputs.
- **Idempotent when possible** — Actions should be safe to re-run (e.g.,
  `cd/release/tag-and-release` skips if the tag exists).
- **Environment variables for sensitive data** — Use `env` blocks rather than
  inline interpolation for values that might contain special characters.

## Reusable workflow caller contract

The `permissions:` blocks of a `workflow_call` workflow — workflow-level
and job-level alike — are **requests against the caller**, not grants.
GitHub validates at workflow startup that the calling job's effective
permissions cover every requested scope; a caller that does not is
rejected with `startup_failure` before any job runs, and no checks are
registered on the PR.

Treat any **addition** to a `permissions:` block in a `workflow_call`
workflow as a breaking change to the caller contract:

- It requires a coordinated consumer rollout: every consumer must add the
  grant to its calling job **before** the rolling tag is promoted to a
  release containing the new request. Grants are backward-compatible
  (callers may grant more than a called workflow requests), so consumer
  patches can always land first.
- Call the new requirement out prominently in the release notes, under a
  **Breaking change** heading.
- Removing or narrowing a request is non-breaking and needs no rollout.

Incident [#698](https://github.com/vergil-project/vergil-actions/issues/698)
is the cautionary tale: v2.1.3 added `actions: read` to `ci-security.yml`'s
request and broke every consumer of `@v2.1` at the moment of promote.
Follow-ups
[#699](https://github.com/vergil-project/vergil-actions/issues/699)
(consumer-refresh release stage) and
[#700](https://github.com/vergil-project/vergil-actions/issues/700)
(release-gate permissions diff) track automating this policy.

## Testing via self-referencing CI

This repository tests its own actions by using local path references in its CI
workflow (`uses: ./.github/workflows/ci-quality.yml`) and in the reusable
workflows that call the composite actions:

```yaml
- uses: ./actions/shared/setup/vergil   # Not the remote reference
```

When you modify an action, the PR's CI run uses your modified version. This
provides integration testing without a separate test repository.

## Branching workflow

- **Protected branches**: `main` and `develop` — no direct commits.
- **Branch naming**: work branches are `<type>/<N>-<slug>`, where `<type>` is
  `feature`, `bugfix`, `hotfix` or `chore` and `<N>` is the GitHub issue
  number (e.g. `feature/42-add-check`). `release/*` branches are created by
  `vrg-release`.
- Feature and bugfix PRs target `develop` with squash merge.
- Release PRs target `main` with regular merge.

## Committing

Always use `vrg-commit`:

```bash
vrg-commit \
  --type feat \
  --scope ci \
  --message "add new validation check"
```

Required flags:

- `--type`: `feat|fix|docs|style|refactor|test|chore|ci|build|revert`
- `--scope`: Conventional commit scope
- `--message`: Commit description

Optional flags:

- `--body`: Detailed commit body
- `--allow-empty`: Allow a commit with no staged changes (e.g. to re-trigger CI)

## Submitting PRs

PR submission is split between the agent and the human. Agents never run
`vrg-submit-pr`.

1. **Agent: push the branch, then record the PR metadata.** Push the branch to
   origin first — `report-ready` pushes only its metadata ref, not the branch:

    ```bash
    vrg-git push -u origin feature/42-add-check
    vrg-pr-workflow report-ready \
      --issue 42 \
      --title "feat(ci): add new validation check" \
      --summary "Add new validation check" \
      --notes "Validated with vrg-validate."
    ```

    `--issue`, `--title`, `--summary` and `--notes` are required and must be
    non-empty. `--linkage` defaults to `Ref`; leave it there, because
    `vrg-submit-pr` picks the keyword at submit time. If the change touches
    `.github/workflows/**`, GitHub refuses the agent's push; the human's
    `vrg-submit-pr` pushes the branch instead.

    `report-ready` freezes the branch: further commits and pushes are refused.
    Re-running it to correct the title, summary or notes is allowed. More work
    belongs in a new follow-up issue; `vrg-pr-workflow unfreeze` reopens a
    branch that has not been submitted.

2. **Human: submit the PR.** Run `vrg-submit-pr` with no arguments from the
   worktree, or `vrg-submit-pr <branch> [<branch> …]` from the main worktree.
   It reads the recorded metadata, previews the PR and opens it after
   confirmation.

3. **Human: merge and clean up.** Run `vrg-finalize-pr`, which waits for checks,
   merges the PR and removes the merged branch and worktree.

The recorded title, summary and notes are readable by anyone on a public
repository, so they must not contain secrets.
