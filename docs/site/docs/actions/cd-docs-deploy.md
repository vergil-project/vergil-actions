# docs-deploy

Deploys MkDocs documentation using mike for versioned documentation. Handles
git configuration, version detection, and mike deploy/set-default.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/cd/docs/deploy@v2.1
  with:
    version-command: cat VERSION | cut -d. -f1,2
    mkdocs-config: docs/site/mkdocs.yml
    mike-command: mike
    git-user-name: ${{ steps.git-identity.outputs.name }}
    git-user-email: ${{ steps.git-identity.outputs.email }}
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `version-command` | **Yes** | — | Shell command to extract the version string on main (e.g. `cat VERSION`, `grep -oP ... version.go`). |
| `mkdocs-config` | No | `docs/site/mkdocs.yml` | Path to mkdocs.yml configuration file. |
| `mike-command` | No | `mike` | Command to run mike. Set to `uv run mike` for Python repos that manage their own dependencies via their project's virtual environment. |
| `git-user-name` | **Yes** | — | The `user.name` of the deploy commit. `cd-docs.yml` passes the org automation App's `<app-slug>[bot]`. |
| `git-user-email` | **Yes** | — | The `user.email` of the deploy commit. `cd-docs.yml` passes the App bot user's noreply address, `<user-id>+<app-slug>[bot]@users.noreply.github.com`. |

A composite action does not enforce `required`, so the action checks both
identity inputs itself: an empty one fails the deploy. There is no default
identity.

## Permissions

- The checkout's persisted credentials must be able to push the `gh-pages`
  branch (Contents write). `cd-docs.yml` checks out with a Contents-write
  token of the org automation App, so its `GITHUB_TOKEN` stays read-only.

## Behavior

1. **Configure git identity** — Sets the git user of the deploy commit from
   the `git-user-name` and `git-user-email` inputs, and fails when either is
   empty. Marks the workspace as a safe directory to avoid dubious-ownership
   errors in container jobs.
2. **Determine version** — On `main`, runs the `version-command` to extract the
   version and sets `alias=latest`. On all other branches, sets `version=dev`
   with no alias.
3. **Stage changelog and release notes** — Copies `CHANGELOG.md` and
   `releases/*.md` into the docs directory, and generates a release notes index
   page sorted by semver. Uses system Python (`/usr/local/bin/python3`) to avoid
   venv PATH shadowing.
4. **Patch mkdocs nav** — Injects release version entries into the `mkdocs.yml`
   nav under the Releases section.
5. **Deploy docs** — On `main`, runs `mike deploy --push --update-aliases
   <version> latest` followed by `mike set-default --push latest`. On other
   branches, runs `mike deploy --push dev`, then makes `dev` the default
   version only while the site has no release. See
   [Default version](#default-version).

### Default version

The default version is the one the site root redirects to. A release makes
`latest` the default. A develop deploy makes `dev` the default only while no
version carries the `latest` alias, which it reads from `mike list --json`.
Once a release exists, a develop deploy leaves the default alone.

mike records the default only as the root `index.html` that `mike set-default`
writes, not in `versions.json`, so `mike list` does not show it. An earlier
guard looked for a `[default]` marker that `mike list` never prints, so every
develop deploy reset a released site's default to `dev` (issue #1214). If
`mike list` fails, the deploy fails and the default is not changed. The logic
is in the action's `deploy.sh`, and `tests/default.test.sh` checks it with the
real mike. The `smoke-cd-docs.yml` workflow runs that test.

## Reusable workflow

Docs deployment is typically consumed via the `cd-docs.yml` reusable workflow
rather than calling the composite action directly:

```yaml
jobs:
  docs:
    uses: vergil-project/vergil-actions/.github/workflows/cd-docs.yml@v2.1
    permissions:
      contents: read
    # `inherit` within the org: it carries the App keys from the `automation`
    # environment. A caller in another org passes APP_CLIENT_ID and
    # APP_PRIVATE_KEY by name, since `inherit` reaches only a reusable
    # workflow in the caller's own organization or enterprise.
    secrets: inherit
```

### The App identity

`cd-docs.yml`'s `docs` job deploys as the org automation App (epic
[vergil-project/.github#1494](https://github.com/vergil-project/.github/issues/1494),
spec §5.4). It runs in the `automation` environment, which holds the App's
`APP_CLIENT_ID` and `APP_PRIVATE_KEY`, and:

1. mints an App token scoped to the calling repository, with only Contents
   write;
2. checks out with that token, so the `gh-pages` push uses it;
3. looks up the App's bot user and passes `<app-slug>[bot]` and its noreply
   address to this action as the commit identity.

The workflow's `GITHUB_TOKEN` is read-only. The secrets are declared
optional, but a caller that passes none fails the `docs` job at its token
step: there is no fallback to `GITHUB_TOKEN`.
`actions/ops/report/tests/app-identity.test.sh` guards this.

### Operations-queue reporting

`cd-docs.yml` also takes a boolean `report` input (default `true`). Its
`report` job reports a develop deploy to the org's operations queue as
`docs-deploy-develop`, through [`ops/report`](ops-report.md).
`report: false` keeps that job off; `cd-docs-refresh.yml` passes it, because
the refresh reports its own run.

### Interpreter source

The action's "Deploy docs" step sets `UV_PYTHON_PREFERENCE=only-system`, and
the `cd-docs.yml` `docs` job sets it in its job `env` too, so it also reaches
the pre-deploy command. For Python repositories, `uv run mike` and
`uv run mkdocs` then use the image's Python, never a managed Python that uv
downloads because the repository sets `python-preference = "only-managed"`. If
the image cannot satisfy the repository's `requires-python`, the deploy fails
loudly. Only the source is pinned: `UV_PYTHON` is not set (epic
vergil-project/.github#407, spec §6.5; issue #1002). The pin is on the step,
so a direct caller of this action gets it without setting anything.

### MkDocs 2.0 banner

The `cd-docs.yml` workflow sets `NO_MKDOCS_2_WARNING=1` on its "Deploy docs"
step, which reaches the `mkdocs` and `mike` processes this action starts.
Without it, mkdocs-material 9.7.x prints a
[MkDocs 2.0 warning banner](https://squidfunk.github.io/mkdocs-material/blog/2026/02/18/mkdocs-2.0/)
on every build. Callers of `cd-docs.yml` cannot set it, because a caller's `env`
does not reach a reusable workflow. The workflow sets the variable, not the
action, so to hide the banner when you call the action directly, set it in that
step's `env`. The variable only hides the banner. Consumers still pin `mkdocs<2`
in their own docs dependencies. Added in v2.1.43 (#947, PR #948).

## Examples

### Direct usage (standalone)

```yaml
- uses: vergil-project/vergil-actions/actions/cd/docs/deploy@v2.1
  with:
    version-command: cat VERSION | cut -d. -f1,2
    git-user-name: ${{ steps.git-identity.outputs.name }}
    git-user-email: ${{ steps.git-identity.outputs.email }}
```

### Python repo with uv-managed dependencies

```yaml
- uses: vergil-project/vergil-actions/actions/cd/docs/deploy@v2.1
  with:
    version-command: cat VERSION | cut -d. -f1,2
    mike-command: uv run mike
    git-user-name: ${{ steps.git-identity.outputs.name }}
    git-user-email: ${{ steps.git-identity.outputs.email }}
```

## GitHub configuration

- **GitHub Pages** — Enable GitHub Pages in repository settings with source set
  to **Deploy from a branch** and branch set to `gh-pages`.
- The `gh-pages` branch is created automatically by `mike deploy --push` on
  first run.
