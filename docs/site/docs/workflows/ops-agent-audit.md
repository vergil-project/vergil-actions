# ops-agent-audit

The daily audit of agent merges (epic
[vergil-project/.github#1384](https://github.com/vergil-project/.github/issues/1384)).
Every managed repository's `ops.yml` calls this workflow after its config
job, as a job named `agent-audit`. It runs
`vrg-agent-audit --repo <calling repo>` as the org automation App.

The audit checks every merge into `develop` and `main` since the
repository's two markers, the branches `vergil/agent-audit/develop` and
`vergil/agent-audit/main`, each holding the last merge commit it audited on
its branch. It then moves each marker to where its audit reached. For each
merge it checks:

- that the merge or auto-merge actor is one it expects: the human, the user
  agent, or the automation App on PRs the App authored;
- on a PR an agent opened or acted on, that a merge-review record or an
  approved exemption covers the merged head's change;
- that nobody but the human merged into `main`.

It is a **security-signal job**. It files no issue, posts nothing and has
no reporting job, since a security signal never goes to a public ops issue
(epic
[vergil-project/.github#1494](https://github.com/vergil-project/.github/issues/1494),
spec §2.3). Its findings are its exit status and its run log, which
`hoshin` reads by the job name `agent-audit`.

The audit never creates a marker. A repository gets both when
`vrg-github-repo-init` creates or adopts it; a scheduled run that finds one
missing reports a `missing-marker` finding and fails.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |

## Secrets

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `APP_CLIENT_ID` | yes | Client ID of the org's automation GitHub App (`<org>-automation`) |
| `APP_PRIVATE_KEY` | yes | Private key of the org's automation GitHub App |

Both live in the calling repository's `automation` environment, which the
job declares (see
[The `automation` environment](https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md#the-automation-environment)).

## Variables

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `VRG_TRUSTED_AUTHORS` | yes | Org-level Actions variable holding the trusted-authors configuration, published with `vrg-trusted-authors publish` (see [VRG_TRUSTED_AUTHORS](../configuration.md#vrg_trusted_authors)). The human and agent logins come from it. The audit fails when it is missing, or names no human or more than one |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `agent-audit` | `<caller> / agent-audit` | From `develop` only: runs `vrg-agent-audit --repo <calling repo>` as the automation App |

## Behavior

The `agent-audit` job runs in `ghcr.io/vergil-project/<prefix>-base:latest`:

1. Fails unless the run's ref is `refs/heads/develop`, before any token is
   minted: the token can move the audit markers, so it is only ever minted
   for a run of `develop`'s code.
2. Mints an App token scoped to the calling repository only.
3. Checks out `develop` with its full history (`fetch-depth: 0`). The audit
   needs a full-history clone whose `origin` is the audited repository, and
   refuses a shallow one.
4. Installs vergil-tooling.
5. Runs `vrg-agent-audit --repo "$REPO"` with the App token as `GH_TOKEN`.
   The audit fetches what it reads, each merged PR's head from
   `refs/pull/<n>/head` and the markers, through the checkout's read-only
   `GITHUB_TOKEN`. Only its API calls, the marker moves among them, use the
   App token.

The exit codes are a contract:

| Exit | Meaning | Job result |
| ---- | ------- | ---------- |
| `0` | Every merge since the markers is clean | Pass |
| `1` | At least one finding, a missing marker, or a read failure | Fail |
| `2` | A usage error | Fail |

Each finding is one line of the log. A read failure is never treated as a
pass.

### Token permissions

| Requested App permission | Why |
| ------------------------ | --- |
| `contents: write` | Move the `vergil/agent-audit/*` marker refs (the "Agent audit markers" ruleset lets only the admin role and the automation App do so), and list the PRs of a commit |
| `pull-requests: read` | Read each merged PR, its reviews and its timeline |
| `issues: read` | Read the PR's timeline, and the task issue's comments that hold its merge-review record |
| `metadata: read` | Always included, stated so the token's whole permission set is explicit |

### Concurrency and timeout

The job runs in the per-repository concurrency group
`${{ github.repository }}/agent-audit`, with `cancel-in-progress: false`:
two runs would audit from the same marker and race to move it. It is capped
at 60 minutes, the life of the App token it moves the markers with.

## Permissions

| Scope | Level | Reason |
| ----- | ----- | ------ |
| `contents` | `read` | Checkout and the audit's own fetches. Every API call uses the App token, not `GITHUB_TOKEN` |

## Usage

The job in a repository's `ops.yml`, after its `github-config` job. A
caller in vergil-project passes `secrets: inherit`, the one way the
`automation` environment's secrets reach a reusable workflow in another
repository:

```yaml
jobs:
  github-config:
    uses: vergil-project/vergil-actions/.github/workflows/ops-github-config.yml@v2.1
    permissions:
      contents: read
      issues: write
    secrets: inherit

  agent-audit:
    needs: github-config
    uses: vergil-project/vergil-actions/.github/workflows/ops-agent-audit.yml@v2.1
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
