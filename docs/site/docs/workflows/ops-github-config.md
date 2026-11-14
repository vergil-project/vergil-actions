# ops-github-config

Nightly per-repository ops checks. Every managed repository's `ops.yml` calls
this workflow on a schedule, and it runs three independent jobs against the
calling repository:

- **`branch-sweep`** deletes branches whose pull-request work is finished.
- **`github-config`** keeps the repository in sync with its expected
  configuration with `vrg-github-repo-config update`, as the org automation
  App, and runs only from `develop`.
- **`dependabot-audit`** fails when the repository has any open Dependabot
  alert, at any severity.

The jobs do not depend on each other, so one failing does not stop the
others. Each one mints its own GitHub App token from the org's automation App
(see [APP_CLIENT_ID and APP_PRIVATE_KEY](../configuration.md#app_client_id-and-app_private_key)),
scoped to the calling repository only.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |

## Secrets

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `APP_CLIENT_ID` | yes | Client ID of the org's automation GitHub App (`<org>-automation`) |
| `APP_PRIVATE_KEY` | yes | Private key of the org's automation GitHub App |

## Variables

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `VRG_AUTOMATION_APP` | yes | Org-level Actions variable holding the automation App's slug (`<org>-automation`), visible to the calling repository (see [step 10 of the App setup](../configuration.md#app_client_id-and-app_private_key)). The `github-config` job fails when it is empty |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `branch-sweep` | `<caller> / branch-sweep` | Deletes finished branches via [`ops/github-config/branch-sweep`](../actions/ops-github-config-branch-sweep.md) |
| `github-config` | `<caller> / github-config` | From `develop` only: runs `vrg-github-repo-config update --repo <calling repo>` as the automation App |
| `dependabot-audit` | `<caller> / dependabot-audit` | Runs `vrg-dependabot-audit --repo <calling repo>` |

## Behavior

Every job runs in `ghcr.io/vergil-project/<prefix>-base:latest` and follows
the same pattern:

1. Mints an App token with `actions/create-github-app-token`. None of the
   jobs passes an `owner` or `repositories` input, so each token is scoped to
   the calling repository alone, and each passes explicit `permission-*`
   inputs, so it carries only the permissions that job needs.
2. Checks out the repository and installs vergil-tooling.
3. Runs its command with the App token as `GH_TOKEN`.

### Token permissions per job

| Job | Requested App permissions | Why |
| --- | ------------------------- | --- |
| `branch-sweep` | `contents: write`, `pull-requests: read` | Delete a branch ref, and read pull requests to decide which branches are finished |
| `github-config` | `administration: write`, `contents: write`, `pull-requests: write`, `workflows: write`, `metadata: read` | `update` reads and converges repository settings, branch protection, rulesets (GitHub returns a ruleset's `bypass_actors` only to a caller that can edit it), Actions permissions and whether vulnerability alerts are enabled (Administration). It pushes the sync branch, and GitHub returns a repository's merge settings only to a token with Contents read and write (see [Get a repository](https://docs.github.com/en/rest/repos/repos#get-a-repository)) (Contents). It opens the sync PR, closes an earlier one and turns on auto-merge (Pull requests), and a sync PR can change files under `.github/workflows/` (Workflows). It makes no Issues call. Minted only after the job has checked that it runs from `develop` and that `VRG_AUTOMATION_APP` is set |
| `dependabot-audit` | `vulnerability-alerts: read` only (**Dependabot alerts: Read**) | List the repository's open Dependabot alerts |

The org's automation App holds more than any one job requests, Administration
write included (see
[App permissions](../configuration.md#app_client_id-and-app_private_key)).
Without the `permission-*` inputs a minted token would carry all of it, so
every job asks only for its own set (see
[Token scoping](../configuration.md#token-scoping)).

`GITHUB_TOKEN` cannot do this work. This workflow requests only
`contents: read` for it, and a called workflow can never hold more than its
caller's `ops.yml` grants (the standard `ops.yml` grants `contents: read` and
`issues: write`). Neither can delete a branch or read Dependabot alerts.

### Concurrency

Each job runs in its own per-repository concurrency group,
`${{ github.repository }}/<job>` (for example
`vergil-project/vergil-tooling/github-config`), with
`cancel-in-progress: false`. A new run of a job waits for a running one of
the same job in the same repository and neither is cancelled, so a scheduled
run and a manual dispatch never overlap. The jobs stay independent of each
other.

### Git credentials

The `github-config` job runs `gh auth setup-git` with the App token as
`GH_TOKEN` before the tool runs. git then gets its HTTPS credentials from
`gh`, so any `git clone` or `git push` vergil-tooling makes authenticates as
the App with this job's scoped token, not with the checkout's
`GITHUB_TOKEN`.

It then sets git's global `user.name` to `<app-slug>[bot]`, from the token
step's `app-slug` output, and `user.email` to
`<id>+<app-slug>[bot]@users.noreply.github.com`, with `<id>` the bot user's
ID from `gh api /users/<app-slug>[bot]`. This follows the pattern in
`actions/create-github-app-token`'s README, so sync commits show as the
automation App.

### branch-sweep

The scheduled safety net behind the delete-on-merge repository setting and
the delete-on-close rule. It lives in this workflow so that every repository
whose `ops.yml` already calls it is swept with no consumer change. See
[`ops/github-config/branch-sweep`](../actions/ops-github-config-branch-sweep.md)
for what is deleted, the job summary and the failure handling.

### github-config

The automatic fleet sync (epic
[vergil-project/.github#1064](https://github.com/vergil-project/.github/issues/1064)).
The job runs `vrg-github-repo-config update --repo "${{ github.repository }}"`
as the org automation App. It converges the repository's GitHub settings and
rulesets, then checks the managed files committed on `develop`, in a fresh
clone. When any has drifted from its released master copy, it opens one sync
PR on an `automation/repo-config-sync/<run-id>` branch with auto-merge on, and
the PR merges itself once its required checks pass. What `update` cannot fix
is left for a human and named in the PR body and the log. For the exit codes
and what each step does, see vergil-tooling's
[`vrg-github-repo-config update`](https://vergil-project.github.io/vergil-tooling/latest/reference/config-audit/#the-update-command)
reference.

**Automation identity.** The update step sets `VRG_AUTOMATION_APP` from the
org-level Actions variable of the same name, next to the App token in
`GH_TOKEN`. vergil-tooling then resolves the `automation` identity mode, and
checks that `GH_TOKEN` was minted by that App before it does any automation
work. The identity is used only for this mechanized work, never for anything
an AI agent does. The variable says the process holds the App's token, so it
is set only on that step, never on the job: a vergil-tooling command that sees
it without the token, such as the setup action's `vrg-whoami` check, fails.
The `smoke-setup-vergil` workflow runs
`actions/ops/github-config/tests/automation-env.test.sh`, which holds every
workflow to this.

**Develop only.** This job holds the workflow's only Administration write
token, so no other branch's code may ever run with it. Its first step,
before any token is minted, fails the job unless the run's ref is
`refs/heads/develop`, and it checks out `develop` explicitly. The same step
fails the job when `VRG_AUTOMATION_APP` is empty. Every fleet repository's
default branch is `develop`, so scheduled runs pass the check. A
`workflow_dispatch` from any other branch fails.

**Time limit.** The job sets `timeout-minutes: 60`. The automation App's
installation token has a fixed one-hour life, and `update`'s wait for its
sync PR to merge ends within it, so a run that takes longer could not use its
token anyway. Without the cap GitHub's default of 360 minutes would apply,
and a run hung outside the tool's own deadline would hold the job's
concurrency group for up to six hours. A run that comes close to the limit is
a cue to look at the job's performance.

### dependabot-audit

The fleet runs Dependabot **report-only** (epic
[vergil-project/.github#420](https://github.com/vergil-project/.github/issues/420)):
alerts are on, Dependabot never opens a pull request, and this job turns any
open alert into a red nightly run. It runs
`vrg-dependabot-audit --repo "${{ github.repository }}"`. Dismissing an alert
on GitHub is the only way to clear it.

The exit codes are a contract:

| Exit | Meaning | Job result |
| ---- | ------- | ---------- |
| `0` | No open alerts | Pass |
| `1` | At least one open alert, at any severity | Fail |
| `2` | The alerts could not be read: alerts disabled, the token lacks Dependabot alerts: Read, no App installation, or an unknown repository | Fail |

"Could not check" (exit 2) is never treated as a pass. A common cause is an
App permission change that has not yet been accepted on the org's
installation: until it is, minted tokens do not carry the new permission. See
[Changing a permission later](../configuration.md#app_client_id-and-app_private_key).

A private repository's log carries an itemized report. A public repository,
or one whose visibility cannot be resolved, gets counts by severity and a
link to the Security tab only, so a world-readable log never names a
vulnerable package.

For the command's full reference, see vergil-tooling's
[Dependabot Alert Audit](https://vergil-project.github.io/vergil-tooling/latest/reference/dependabot-audit/).

## Permissions

| Scope | Level | Reason |
| ----- | ----- | ------ |
| `contents` | `read` | Checkout. Every other operation uses the App token, not `GITHUB_TOKEN` |

## Usage

The standard `ops.yml`, as generated by vergil-tooling's `vrg-github-repo-init`
(which staggers the cron minute per repository):

```yaml
name: Ops

on:
  schedule:
    - cron: '45 6 * * *'
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  github-config:
    uses: vergil-project/vergil-actions/.github/workflows/ops-github-config.yml@v2.1
    permissions:
      contents: read
      issues: write
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```
