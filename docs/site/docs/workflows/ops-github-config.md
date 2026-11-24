# ops-github-config

Nightly per-repository ops checks. Every managed repository's `ops.yml` calls
this workflow on a schedule, and it runs four independent jobs:

- **`branch-sweep`** deletes the calling repository's branches whose
  pull-request work is finished.
- **`github-config`** keeps the calling repository in sync with its expected
  configuration with `vrg-github-repo-config update`, as the org automation
  App, and runs only from `develop`.
- **`trusted-authors-check`** checks the org's trusted-authors Actions
  variables with `vrg-trusted-authors check`, as the org automation App, and
  uploads the values it read as the `trusted-authors-values` artifact. It
  runs only in the org's own `.github` repository (`<org>/.github`) and is
  skipped in every other calling repository.
- **`dependabot-audit`** fails when the calling repository has any open
  Dependabot alert, at any severity.

The jobs do not depend on each other, so one failing does not stop the
others. Each one mints its own GitHub App token from the org's automation App
(see [APP_CLIENT_ID and APP_PRIVATE_KEY](../configuration.md#app_client_id-and-app_private_key)).
Every token is scoped to the calling repository only, except
`trusted-authors-check`'s, which reads every repository of the org and holds
read-only permissions only.

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
| `VRG_AUTOMATION_APP` | yes | Org-level Actions variable holding the automation App's slug (`<org>-automation`), visible to the calling repository (see [step 10 of the App setup](../configuration.md#app_client_id-and-app_private_key)). The `github-config` and `trusted-authors-check` jobs fail when it is empty |
| `VRG_TRUSTED_AUTHORS` | yes | Org-level Actions variable holding the trusted-authors configuration, published with `vrg-trusted-authors publish` (see [VRG_TRUSTED_AUTHORS](../configuration.md#vrg_trusted_authors)). Passed to the `branch-sweep` job's [`ops/github-config/branch-sweep`](../actions/ops-github-config-branch-sweep.md) step, the `github-config` job's update step, the `dependabot-audit` job's audit step and the `report-branch-sweep` job's `ops/report` step, which stop when it is missing or invalid. The `trusted-authors-check` step needs none (see [trusted-authors-check](#trusted-authors-check)) |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `branch-sweep` | `<caller> / branch-sweep` | Deletes finished branches via [`ops/github-config/branch-sweep`](../actions/ops-github-config-branch-sweep.md) |
| `github-config` | `<caller> / github-config` | From `develop` only: runs `vrg-github-repo-config update --repo <calling repo>` as the automation App |
| `trusted-authors-check` | `<caller> / trusted-authors-check` | In `<org>/.github` only (skipped elsewhere): runs `vrg-trusted-authors check --org <calling repo's owner>` as the automation App and uploads the `trusted-authors-values` artifact |
| `dependabot-audit` | `<caller> / dependabot-audit` | Runs `vrg-dependabot-audit --repo <calling repo>` |
| `report-branch-sweep` | `<caller> / report-branch-sweep` | Always, after `branch-sweep`: reports its result as `branch-sweep` to the org's operations queue through [`ops/report`](../actions/ops-report.md) |

`github-config`, `trusted-authors-check` and `dependabot-audit` get no
reporting job: their failures are security signals, which never go to a
public ops issue (epic
[vergil-project/.github#1494](https://github.com/vergil-project/.github/issues/1494),
spec §2.3).

## Behavior

Every job runs in `ghcr.io/vergil-project/<prefix>-base:latest` and follows
the same pattern:

1. Mints an App token with `actions/create-github-app-token`. Each job
   passes explicit `permission-*` inputs, so its token carries only the
   permissions that job needs. No job but `trusted-authors-check` passes an
   `owner` or `repositories` input, so each other token is scoped to the
   calling repository alone.
2. Checks out the repository and installs vergil-tooling.
3. Runs its command with the App token as `GH_TOKEN`.

`branch-sweep` and `dependabot-audit` check the token before they use it:
a step between the install and the command runs `vrg-whoami --mode` with the
App token and `VRG_AUTOMATION_APP`, and fails unless it prints `automation`.
vergil-tooling then verifies that the token was minted by the App the
variable names, and an empty variable fails the step too. `github-config` and
`trusted-authors-check` set `VRG_AUTOMATION_APP` on their command's step
instead, whose command makes the same check (below).
`actions/ops/report/tests/app-identity.test.sh` guards the order.

`github-config` is the exception: its first step, before any token is minted,
fails the job unless the ref is `refs/heads/develop` and `VRG_AUTOMATION_APP`
is set, and its checkout pins `ref: develop` (see
[github-config](#github-config)).

### Token permissions per job

| Job | Requested App permissions | Why |
| --- | ------------------------- | --- |
| `branch-sweep` | `contents: write`, `pull-requests: read` | Delete a branch ref, and read pull requests to decide which branches are finished |
| `github-config` | `administration: write`, `contents: write`, `pull-requests: write`, `workflows: write`, `actions: read`, `metadata: read` | `update` reads and converges repository settings, branch protection, rulesets (GitHub returns a ruleset's `bypass_actors` only to a caller that can edit it), Actions permissions and whether vulnerability alerts are enabled (Administration). It pushes the sync branch, and GitHub returns a repository's merge settings only to a token with Contents read and write (see [Get a repository](https://docs.github.com/en/rest/repos/repos#get-a-repository)) (Contents). It opens the sync PR, closes an earlier one and turns on auto-merge (Pull requests), and a sync PR can change files under `.github/workflows/` (Workflows). It reads the `automation` environment and its deployment branch policies, which GitHub serves only to a token with Actions read (Actions). It makes no Issues call. Minted only after the job has checked that it runs from `develop` and that `VRG_AUTOMATION_APP` is set |
| `trusted-authors-check` | `organization-actions-variables: read`, `actions-variables: read`, `metadata: read` (organization and repository **Variables: Read**), for the org's whole installation (`owner: ${{ github.repository_owner }}`) | Read the org variables and every repository's variables. `actions/create-github-app-token` declares no input for either Variables permission, but it turns every `permission-*` input into a token permission; `.github/actionlint.yaml` ignores exactly these two inputs |
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
workflow to this. A step that sets `VRG_AUTOMATION_APP` must carry the App's
identity in exactly one of two forms:

- **The token form:** `GH_TOKEN` from an earlier token step of its job
  (`${{ steps.<id>.outputs.token }}`), as this job's update step does.
- **The credential form:** no `GH_TOKEN`, and `VRG_AUTOMATION_CLIENT_ID`
  and `VRG_AUTOMATION_PRIVATE_KEY` both from `${{ secrets.<name> }}`. This
  is for a tool that mints its own repo-scoped token, as
  `vrg-upstream-refresh publish` does in
  [ops-upstream-refresh](ops-upstream-refresh.md).

Any other shape fails the check, and so does a step that has both forms at
once.

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

### trusted-authors-check

The daily check of the trusted-authors Actions copies (epic
[vergil-project/.github#1467](https://github.com/vergil-project/.github/issues/1467)).
The org variables `VRG_TRUSTED_AUTHORS` and `VRG_AUTOMATION_APP` are
derived from the human's host configuration and published by the human with
`vrg-trusted-authors publish` (see
[VRG_TRUSTED_AUTHORS](../configuration.md#vrg_trusted_authors)). The job runs
`vrg-trusted-authors check --org "${{ github.repository_owner }}"
--values-out trusted-authors-values.json`, which flags a missing or invalid
org variable, one not visible to every repository, and any repository-level
variable of either name, since that would override the org copy in its
repository's jobs.

**Automation identity.** The check step sets `VRG_AUTOMATION_APP` next to
the App token in `GH_TOKEN`, as `github-config`'s update step does, so
vergil-tooling verifies that the token was minted by the automation App.
`check` refuses the agent identity modes. With `--org` it reads no
trusted-authors configuration, so this step, unlike the workflow's other
`vrg-*` steps (see [Variables](#variables)), needs no `VRG_TRUSTED_AUTHORS`.
The `smoke-setup-vergil` workflow runs
`actions/ops/github-config/tests/trusted-authors-check.test.sh`, which holds
the job to where it runs, its identity, its token's scope and permissions,
and the upload.

The exit codes:

| Exit | Meaning | Job result |
| ---- | ------- | ---------- |
| `0` | The variables are clean | Pass |
| `1` | At least one finding, printed as a `FINDING:` line | Fail |
| `2` | The check could not run, for example a failed read or an empty `VRG_AUTOMATION_APP` | Fail |

**The values artifact.** On success and on failure (`if: always()`), the job
uploads the `--values-out` file as the artifact `trusted-authors-values`:
`{"<org>": {"<name>": "<value>"}}`, the values the check read, logins and
slugs only. `hoshin start` compares it with the values the host
configuration implies, so drift between the source and the published copy
is caught. When the check could not run it writes no file, and the upload
step fails too.

**Where it runs.** The check covers the whole org, so one run a night is
enough. The job runs only in the org's own `.github` repository: its condition
is `if: github.repository == format('{0}/.github', github.repository_owner)`,
which names that repository from the calling repository's owner, so it holds
for any org. In every other repository whose `ops.yml` calls this workflow,
the job is skipped. That one run's artifact is the org's single latest
configuration-audit result, and a finding turns only the `.github`
repository's nightly run red.

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

The log carries counts by severity and a link to the Security tab only, so
a world-readable log never names a vulnerable package.

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
    - cron: '45 1 * * *'
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
