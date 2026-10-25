# ops-upstream-refresh

Scheduled upstream refresh. It runs `vrg-upstream-refresh`, which runs the
calling repository's `[upstream-refresh].hook` from `vergil.toml` and turns
the result into at most one pull request:

- **No change.** The run exits quietly. If a refresh PR is still open, it is
  closed with a comment and its branch is deleted, because the base branch
  already has the change or it no longer applies.
- **A change.** The change is committed to the fixed `upstream-refresh`
  branch, which is force-pushed only when its content differs, and one PR is
  opened or refreshed with the hook's notes in its body. Superseded refresh
  PRs are closed.

The workflow never merges. The PR's own CI checks it, and a human reviews and
merges it. An upstream refresh is separate from a dependency update:
`vrg-upstream-refresh` never runs the `[dependency-update]` hook, and
`vrg-update-deps` never runs the `[upstream-refresh]` hook. See the
vergil-tooling `upstream-refresh` configuration reference for the hook
contract.

Each consumer calls it from its own `ops.yml` on its own schedule.

## Inputs

None.

## Secrets

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `APP_CLIENT_ID` | yes | Client ID of the org's GitHub App |
| `APP_PRIVATE_KEY` | yes | Private key of the org's GitHub App |

The token is scoped to the calling repository only. The App needs
`contents: write` (to push and delete the `upstream-refresh` branch) and
`pull-requests: write` (to open, update, comment on and close the refresh PR)
on that repository.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `upstream-refresh` | `<caller> / upstream-refresh` | Runs `vrg-upstream-refresh` against the branch the run is on |

## Behavior

The `upstream-refresh` job runs in `ghcr.io/vergil-project/prod-base:latest`,
in the concurrency group `upstream-refresh` (a new run waits for a running
one; neither is cancelled):

1. Mints an App token scoped to the calling repository.
2. Checks out the repository with that token, so the push and the PR are
   App-authored. An App-authored PR triggers `pull_request` workflows, which
   a `GITHUB_TOKEN` push does not.
3. Marks the workspace safe for git and sets the git identity to
   `github-actions[bot]`.
4. Installs vergil-tooling at the caller's `[dependencies].vergil` ref.
5. Runs `vrg-upstream-refresh --base "$BASE"` with the App token as
   `GH_TOKEN`. `BASE` is the branch the run is on (`github.ref_name`), passed
   through the environment.

A failed run (a hook that exits non-zero, or leaves untracked files behind)
shows as a red scheduled run.

`vrg-upstream-refresh` refuses the agent identity modes (`user` and `audit`),
because it opens PRs. This workflow sets no agent identity; its GitHub writes
are made with the App token.

## Permissions

| Scope | Level | Reason |
| ----- | ----- | ------ |
| `contents` | `read` | A called workflow cannot exceed its caller's grant. The push and PR writes use the App token, not `GITHUB_TOKEN` |

## Usage

```yaml
name: Ops

on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  upstream-refresh:
    uses: vergil-project/vergil-actions/.github/workflows/ops-upstream-refresh.yml@v2.1
    permissions:
      contents: read
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

Schedule it on the default branch, so `BASE` is that branch.
