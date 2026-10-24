# ops-github-config

Nightly per-repository ops checks. Every managed repository's `ops.yml` calls
this workflow on a schedule, and it runs three independent jobs against the
calling repository:

- **`branch-sweep`** deletes branches whose pull-request work is finished.
- **`github-config`** audits the repository's GitHub configuration with
  `vrg-github-repo-config audit`.
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

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `branch-sweep` | `<caller> / branch-sweep` | Deletes finished branches via [`ops/github-config/branch-sweep`](../actions/ops-github-config-branch-sweep.md) |
| `github-config` | `<caller> / github-config` | Runs `vrg-github-repo-config audit --repo <calling repo>` |
| `dependabot-audit` | `<caller> / dependabot-audit` | Runs `vrg-dependabot-audit --repo <calling repo>` |

## Behavior

Every job runs in `ghcr.io/vergil-project/<prefix>-base:latest` and follows
the same pattern:

1. Mints an App token with `actions/create-github-app-token`. None of the
   jobs passes an `owner` or `repositories` input, so each token is scoped to
   the calling repository alone.
2. Checks out the repository and installs vergil-tooling.
3. Runs its command with the App token as `GH_TOKEN`.

### Token permissions per job

| Job | Requested App permissions | Why |
| --- | ------------------------- | --- |
| `branch-sweep` | `contents: write`, `pull-requests: read` | Delete a branch ref, and read pull requests to decide which branches are finished |
| `github-config` | None requested, so the token carries the installation's full permission set (still limited to the calling repository) | The audit reads repository settings, branch protection, rulesets, Actions permissions, whether vulnerability alerts are enabled, and the repository's `vergil.toml` and CI workflow |
| `dependabot-audit` | `vulnerability-alerts: read` only (**Dependabot alerts: Read**) | List the repository's open Dependabot alerts |

`GITHUB_TOKEN` cannot do this work. This workflow requests only
`contents: read` for it, and a called workflow can never hold more than its
caller's `ops.yml` grants (the standard `ops.yml` grants `contents: read` and
`issues: write`). Neither can delete a branch or read Dependabot alerts.

The audit is read-only, and the App's **Administration** permission is
**Read-only** to match. `vrg-github-repo-config apply`, which changes settings
and rulesets, is a human action run under the maintainer's own `gh` login,
never by this workflow.

### branch-sweep

The scheduled safety net behind the delete-on-merge repository setting and
the delete-on-close rule. It lives in this workflow so that every repository
whose `ops.yml` already calls it is swept with no consumer change. See
[`ops/github-config/branch-sweep`](../actions/ops-github-config-branch-sweep.md)
for what is deleted, the job summary and the failure handling.

### github-config

Runs `vrg-github-repo-config audit --repo "${{ github.repository }}"`, which
compares the repository's live GitHub configuration with the expected
configuration and exits non-zero when they differ or the configuration cannot
be read. It never changes anything. To converge a
repository, a human runs `vrg-github-repo-config apply` (see
[Repository Rulesets](../ci-gates/repository-rulesets.md)).

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
