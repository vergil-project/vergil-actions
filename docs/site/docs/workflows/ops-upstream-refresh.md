# ops-upstream-refresh

Scheduled upstream refresh. It runs `vrg-upstream-refresh`, which runs the
calling repository's `[upstream-refresh].hook` from `vergil.toml` on a fresh
clone of `develop`, and turns the result into at most one pull request that
merges itself:

- **No change.** The run reports "in sync" and exits 0. If an earlier run's
  refresh PR is still open, it is closed and its branch deleted.
- **A change.** The change is checked against the repository's path fence,
  committed as the automation App's bot user, and pushed to a new branch,
  `automation/upstream-refresh/<run-id>`. The PR, titled
  `chore(upstream): refresh upstream inputs`, lists the changed files and
  the hook's notes, and has auto-merge on. The run waits until the PR has
  merged, then exits 0. An earlier run's open refresh PR is closed first.

No human merges a refresh PR: the job merges it, as the org automation App,
once the PR's CI passes. A run is green only when the PR merged or there was
nothing to change. This carries out the policy decided in
[vergil-project/.github#470](https://github.com/vergil-project/.github/issues/470)
(epic
[vergil-project/.github#1168](https://github.com/vergil-project/.github/issues/1168)).

An upstream refresh is separate from a dependency update:
`vrg-upstream-refresh` never runs the `[dependency-update]` hook, and
`vrg-update-deps` never runs the `[upstream-refresh]` hook. For the hook
contract, the path fence and the `[upstream-refresh].paths` allowlist, see
vergil-tooling's
[upstream-refresh reference](https://vergil-project.github.io/vergil-tooling/latest/reference/upstream-refresh-config/).
A repository with no `paths` refuses every patch, so every run with a change
fails until it declares them.

Each consumer calls it from its own `ops.yml` on its own schedule.

## Inputs

| Input | Type | Required | Default | Description |
| ----- | ---- | -------- | ------- | ----------- |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |

## Secrets and variables

| Name | Kind | Required | Description |
| ---- | ---- | -------- | ----------- |
| `APP_CLIENT_ID` | secret | yes | Client ID of the org's automation App |
| `APP_PRIVATE_KEY` | secret | yes | Private key of the org's automation App |
| `VRG_AUTOMATION_APP` | Actions variable | yes | Org-level variable holding the automation App's slug (`<org>-automation`), visible to the calling repository (see [step 10 of the App setup](../configuration.md#app_client_id-and-app_private_key)). Both jobs fail when it is empty |

The secrets reach only the `publish` job's last step. `vrg-upstream-refresh
publish` mints its own installation tokens from them, limited to the calling
repository with `contents: write` (push the PR branch, delete an earlier
run's), `pull-requests: write` (open, merge and close refresh PRs),
`workflows: write` (the wait's branch update, below) and `metadata: read`.
See [Token scoping](../configuration.md#token-scoping).

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `prepare` | `<caller> / prepare` | Runs the hook through `vrg-upstream-refresh prepare`, with no secrets, and uploads the patch |
| `publish` | `<caller> / publish` | Runs `vrg-upstream-refresh publish` on that patch: fence, PR, and the wait until it merges |

## The key boundary

The App's private key never shares a runner with the work: the hook and
anything it installs or loads. Steps in one job share a runner's
filesystem, so code in an earlier step could rewrite the tool, its packages,
or a git hook or config that a later step holding the key then runs. So the
workflow runs as two jobs, each on a fresh runner:

- **`prepare`** runs the hook with no secrets and a read-only
  `GITHUB_TOKEN`, and hands on data only: a patch and its notes, as an
  artifact. `vrg-upstream-refresh prepare` refuses to run if the App's
  credentials are in its environment.
- **`publish`** runs only the trusted platform: the runner, the released
  container image and released vergil-tooling. It treats the artifact as
  data: it never runs it, never runs the hook, and never runs git in a tree
  `prepare` touched. It applies the patch in its own fresh clone of
  `develop`, on the exact commit `prepare` ran against, and reads the path
  fence's rules from that clone's `develop` tip, never from the artifact.

`actions/ops/upstream-refresh/tests/key-boundary.test.sh`, run by the
`smoke-setup-vergil` workflow, holds the workflow to this layout: the
secrets only on `publish`'s last step, no secret and a read-only token on
`prepare`, the guard first in each job, no `if:`, and both time limits.

## Behavior

Both jobs run in
`ghcr.io/vergil-project/<container-prefix>-base:latest` (`prod-base` by
default). The workflow is in the concurrency group
`<owner>/<repo>/upstream-refresh`: a new run waits for a running one,
neither is cancelled, and one run's `prepare` and `publish` never interleave
with another run's.

**`prepare`** (`permissions: contents: read`, `timeout-minutes: 30`):

1. **Guard.** Fails the job unless the run's ref is `refs/heads/develop`
   and `VRG_AUTOMATION_APP` is set. It is a failing step, not a job-level
   `if:`, so a run from another ref shows up red instead of being skipped.
2. Checks out `develop`, with `persist-credentials: false`, only to install
   the tooling.
3. Installs vergil-tooling at the caller's `[dependencies].vergil` ref.
4. Runs `vrg-upstream-refresh prepare`, with the read-only `GITHUB_TOKEN`
   as `GH_TOKEN`. It clones `develop`, runs the hook there, and writes the
   hook's tracked changes as a binary patch, the `develop` commit it ran
   on, the changed paths and the hook's notes.
5. Uploads that output as the `upstream-refresh-prepare` artifact.

**`publish`** (`needs: prepare`, `permissions: contents: read`,
`timeout-minutes: 140`):

1. **Guard**, the same as `prepare`'s, in depth: no App token is minted
   from any other ref.
2. Checks out `develop` and installs vergil-tooling, as in `prepare`, on
   this job's own runner.
3. Downloads the `upstream-refresh-prepare` artifact.
4. Runs `vrg-upstream-refresh publish` on it, with `VRG_AUTOMATION_APP`,
   `VRG_AUTOMATION_CLIENT_ID` and `VRG_AUTOMATION_PRIVATE_KEY` set on this
   step only. The tool removes the credentials from its environment at
   startup, so no `git` or `gh` it starts sees them. It checks every minted
   token against `VRG_AUTOMATION_APP`, applies and fences the patch, and
   opens the PR and waits until it merges.

When `prepare` finds nothing to change, `publish` still runs: it closes an
earlier run's open refresh PR and reports "in sync".

**The token and the wait.** The tool renews its token once it is older than
30 minutes, revokes each token it replaces, and revokes the last one when it
exits, on SIGINT and SIGTERM included. Every `git` and `gh` call takes the
current token, so a wait longer than one token's hour keeps working: a
vergil-containers refresh, whose CI takes 32 to 40 minutes, renews at least
once. If `develop` has moved since `prepare`, the wait updates the PR's
branch from `develop` and CI decides; that merge needs Workflows write
whenever `develop` has changed a workflow file. The path fence refuses any
patch that touches `.github/**`, so no patch can use it. The wait's
deadline is 120 minutes from the tool's own start. `publish`'s
`timeout-minutes: 140` is that deadline, plus 15 minutes for the steps
before the tool, plus a 5-minute margin, so the tool always ends, revokes
its token and logs how the wait ended before GitHub kills the job. Only a
hard kill skips the last revocation (see
[Token scoping](../configuration.md#token-scoping)).

**Exit codes** of `vrg-upstream-refresh publish`, which decide the job's
result:

| Exit | Meaning |
| ---- | ------- |
| 0 | Merged, or nothing to change |
| 2 | The PR was opened but did not merge: the log names the PR and the reason (a failed check, a conflict, a closed PR, the branch-update cap or the deadline) |
| 1 | Any other failure, with the reason: the hook, a clone, the path fence, the base check, a refused identity, a failed mint or revocation |
| 130 or 143 | Interrupted by SIGINT or SIGTERM, such as a cancel, after revoking its token |

A run with a non-zero exit shows as a red scheduled run, and the publish
log alone says what happened: the PR it closed, the PR it opened or "in
sync", each token renewal and revocation, and how the wait ended.

`vrg-upstream-refresh` refuses the agent identity modes (`user` and
`audit`), because it opens and merges PRs. Under GitHub Actions, publish
refuses to run unless it was given the App's credentials and resolves to
the `automation` identity.

## Permissions

| Job | Scope | Level | Reason |
| --- | ----- | ----- | ------ |
| `prepare` | `contents` | `read` | The checkout, and the clone of `develop` the hook runs in. Prepare writes nothing to GitHub |
| `publish` | `contents` | `read` | The checkout. Every write uses the token the tool mints, not `GITHUB_TOKEN` |

A called workflow cannot exceed its caller's grant. The caller's
`contents: read` covers both jobs. The artifact passes between them within
the run, which needs no `GITHUB_TOKEN` permission.

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

Schedule it on the default branch, `develop`: both jobs fail from any other
ref.
