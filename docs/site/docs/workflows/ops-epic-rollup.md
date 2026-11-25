# ops-epic-rollup

Event-driven epic rollup. When an issue closes, it runs
`vrg-epic-rollup`, which closes the issue's parent epic once every task in
that epic is closed.

The rollup is a no-op unless the closed issue is a managed task whose parent
is a finite epic (an `epic`-labelled issue that is not a standing `ad-hoc`
epic), so the caller can run it on every issue close. Epics usually live in a
different repository (the org's `.github`), which is why the workflow uses a
GitHub App token rather than `GITHUB_TOKEN`.

[`ops-epic-sweep`](ops-epic-sweep.md) is the scheduled safety net for any
close this workflow misses.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |
| `epic-repo` | string | no | `.github` | Repository in the caller's org that holds the epics. The App token is scoped to it so the rollup can close the parent epic there |

## Secrets

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `APP_CLIENT_ID` | yes | Client ID of the org's GitHub App |
| `APP_PRIVATE_KEY` | yes | Private key of the org's GitHub App |

The App must be installed on the calling repository and on `epic-repo`, with
`issues: write`.

Both live in the calling repository's `automation` environment. The
`epic-rollup` and `report` jobs declare `environment: automation` and read
them.

## Variables

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `VRG_TRUSTED_AUTHORS` | yes | Org-level Actions variable holding the trusted-authors configuration, published with `vrg-trusted-authors publish` (see [VRG_TRUSTED_AUTHORS](../configuration.md#vrg_trusted_authors)). Passed to the `vrg-epic-rollup` step and to the `report` job's `ops/report` step, which stop when it is missing or invalid |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `epic-rollup` | `<caller> / epic-rollup` | Runs `vrg-epic-rollup` for the closed issue |
| `report` | `<caller> / report` | Always, after `epic-rollup`: reports its result as `epic-rollup` to the org's operations queue through [`ops/report`](../actions/ops-report.md) |

## Behavior

The `epic-rollup` job runs in `ghcr.io/vergil-project/<prefix>-base:latest`:

1. Mints an App token scoped to the calling repository and `epic-repo`,
   requesting only `issues: write`.
2. Checks out the repository and installs vergil-tooling.
3. Runs `vrg-whoami --mode` with the App token and `VRG_AUTOMATION_APP`, and
   fails unless it prints `automation`: vergil-tooling verifies that the
   token was minted by the App the variable names before any write.
4. Runs `vrg-epic-rollup --task "<owner>/<repo>#<issue number>"` with the
   App token as `GH_TOKEN`.

The issue number comes from `github.event.issue.number`, so the caller must be
triggered by an `issues` event.

## Permissions

| Scope | Level | Reason |
| ----- | ----- | ------ |
| `contents` | `read` | Checkout. Issue writes use the App token, not `GITHUB_TOKEN` |

## Usage

A caller in vergil-project passes `secrets: inherit`:

```yaml
name: Epic Rollup

on:
  issues:
    types: [closed]

permissions:
  contents: read

jobs:
  epic-rollup:
    uses: vergil-project/vergil-actions/.github/workflows/ops-epic-rollup.yml@v2.1
    permissions:
      contents: read
    secrets: inherit
```

GitHub's `secrets: inherit` passes secrets only within one organization. A
caller in another org passes the two keys by name instead:

```yaml
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

## This repository's caller: epic-rollup

`.github/workflows/epic-rollup.yml` in this repository is the vergil-project
caller above: it runs on `issues: closed` and passes the App secrets to
`ops-epic-rollup.yml@v2.1`. It is not a reusable workflow. Each managed
repository carries the same thin caller, and all the logic (token, checkout,
install, run) stays in `ops-epic-rollup`.
