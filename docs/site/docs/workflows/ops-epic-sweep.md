# ops-epic-sweep

Scheduled epic and task reconciliation. It runs `vrg-epic-audit --close`,
which makes three passes over the whole org:

- **Drift close.** Closes work that missed its event-driven close, for example
  when the [`ops-epic-rollup`](ops-epic-rollup.md) run failed, a secret was
  broken or two closes raced: epics whose tasks are all closed, and task issues
  whose PR has merged. It also reopens an epic that was closed while a child
  was still open.
- **Archive drain.** Moves the closed children of every standing epic
  (ad-hoc, intake and planning) into per-quarter archive epics.
- **Orphan pass.** Enforces "every issue belongs to an epic": it links
  body-only `Parent:` lines as native sub-issues, removes the retired `triage`,
  `idea` and `research` labels, moves a now-public repository's self-homed
  intake and planning items under the org `.github` queues, and attaches every
  orphan to its home's intake epic.

So the sweep changes labels and sub-issue links, not only issue state. Each
pass acts only on provable drift, so a run with nothing new to fix changes
nothing.

The org's epic home calls it once a day; one run covers the whole org. The
same caller's `workflow_dispatch` trigger is how the one-time migration for
"every issue belongs to an epic" is run.

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
because the sweep closes, relabels, links and moves issues in the code
repositories, and closes, drains and attaches under epics in `.github`. The
App needs `issues: write` on all of them.

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

`vrg-epic-audit --close` runs its passes in this order:

1. Closes drifted tasks and rolled-up epics, and reopens any epic closed with
   an open child.
2. Drains the ad-hoc epics, then the intake and planning epics, into
   per-quarter archives, and closes past archives.
3. Runs the orphan pass: links body-only `Parent:` lines natively, strips the
   retired labels, moves now-public repositories' queue items under `.github`
   (closing each emptied self-homed queue epic), then attaches orphans to
   intake.

The log prints a count line for each step, for example
`Retired kind labels stripped: 41 issue(s).` and
`Orphans attached to intake: 50.`

### When a run fails because a queue is full

An intake or planning epic holds at most 95 open children. When an epic is at
that cap, the orphan pass stops before it adds anything past it. The step
prints every issue it did not link and exits 1, so the run fails. A failed run
can therefore mean the queue needs attention (run intake review, or work the
planning queue), not only a broken token or an outage. The next run attaches
the rest once the queue has room.

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
