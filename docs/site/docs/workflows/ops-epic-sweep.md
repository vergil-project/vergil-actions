# ops-epic-sweep

Scheduled epic and task reconciliation. It runs `vrg-epic-audit --close` to
find and close work that missed its event-driven close, for example when the
[`ops-epic-rollup`](ops-epic-rollup.md) run failed, a secret was broken or two
closes raced.

It closes only provably complete drift: epics whose tasks are all closed, and
task issues whose PR has merged. Running it again changes nothing.

The org's epic home calls it once a day; one run covers the whole org.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |
| `window-days` | string | no | `"30"` | How many days back to look for merged PRs whose task issue is still open. Epic drift (all tasks closed) is not limited by the window |

## Secrets

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `APP_CLIENT_ID` | yes | Client ID of the org's GitHub App |
| `APP_PRIVATE_KEY` | yes | Private key of the org's GitHub App |

The token is minted for every repository the App is installed on in the org,
because the sweep closes tasks in the code repositories and epics in `.github`.
The App needs `issues: write` on all of them.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `epic-sweep` | `<caller> / epic-sweep` | Runs `vrg-epic-audit --close` across the org |

## Behavior

The `epic-sweep` job runs in `ghcr.io/vergil-project/<prefix>-base:latest`:

1. Mints an App token for the caller's org, with no repository restriction.
2. Checks out the repository and installs vergil-tooling.
3. Runs `vrg-epic-audit --close --window-days "$WINDOW_DAYS"` with the App
   token as `GH_TOKEN` and `VRG_EPIC_SWEEP=1`.

`vrg-epic-audit --close` is otherwise a human-only action: it refuses unless
the identity resolves to human. `VRG_EPIC_SWEEP=1` marks this scheduled run as
the trusted automation that may close. An interactive agent session never sets
it.

## Permissions

| Scope | Level | Reason |
| ----- | ----- | ------ |
| `contents` | `read` | Checkout. Issue writes use the App token, not `GITHUB_TOKEN` |

## Usage

```yaml
name: Epic Sweep

on:
  schedule:
    - cron: '0 7 * * *'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  epic-sweep:
    uses: vergil-project/vergil-actions/.github/workflows/ops-epic-sweep.yml@v2.1
    permissions:
      contents: read
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```
