# cd-docs-refresh

Regenerates a docs site's generated pages and republishes the site. It is a
thin wrapper over `cd-docs.yml` with the page generation pre-wired.

It exists for an organization's documentation-site repository, whose roadmap
and activity pages change with epic activity in the org rather than with any
change to the docs repository. There is no push or release to rebuild on, so
the caller runs it on a schedule and on demand.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `pre-deploy-command` | string | no | `vrg-roadmap > docs/site/docs/roadmap.md && vrg-activity-log > docs/site/docs/activity.md` | Command that regenerates the generated pages before the deploy |
| `mkdocs-config` | string | no | `docs/site/mkdocs.yml` | Path to the MkDocs configuration file |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `refresh` | `<caller> / refresh / docs` | Calls `cd-docs.yml`, whose `docs` job runs the command, stages the docs and deploys them |

## Behavior

The `refresh` job calls `cd-docs.yml` with the three inputs. Its `docs` job:

1. Checks out the repository with full history and installs vergil-tooling.
2. Runs `pre-deploy-command`. The default runs `vrg-roadmap` and
   `vrg-activity-log`, which read the org's `.github` epics with `gh`; the step
   sets `GH_TOKEN` to the workflow's `github.token`, which is enough because
   the epic home is public.
3. Stages the changelog and release notes with
   [`shared/docs/stage`](../actions/shared-docs-stage.md).
4. Deploys with [`cd/docs/deploy`](../actions/cd-docs-deploy.md): `mike` for
   a versioned site, or `mkdocs gh-deploy` to the `gh-pages` root for a
   repository with `versioning-scheme = none`.

`cd-docs` runs in the `cd-docs` concurrency group without cancelling, so a
refresh queues behind a deploy that is already running.

The nested call is to `cd-docs.yml@develop`, fully qualified so it resolves
when `cd-docs-refresh` is called from another repository. The release freezes
that ref to the release tag (see
[Reference freezing](index.md#reference-freezing)).

## Permissions

| Scope | Level | Reason |
| ----- | ----- | ------ |
| `contents` | `write` | The deploy pushes the built site to the `gh-pages` branch |

## Usage

```yaml
name: CD Docs Refresh

on:
  schedule:
    - cron: "17 6 * * *"
  workflow_dispatch:

permissions:
  contents: write

jobs:
  refresh:
    uses: vergil-project/vergil-actions/.github/workflows/cd-docs-refresh.yml@v2.1
    permissions:
      contents: write
```

The **Run workflow** button (`workflow_dispatch`) is the manual "refresh now".
