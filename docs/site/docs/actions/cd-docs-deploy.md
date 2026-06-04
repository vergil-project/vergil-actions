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
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `version-command` | **Yes** | — | Shell command to extract the version string on main (e.g. `cat VERSION`, `grep -oP ... version.go`). |
| `mkdocs-config` | No | `docs/site/mkdocs.yml` | Path to mkdocs.yml configuration file. |
| `mike-command` | No | `mike` | Command to run mike. Set to `uv run mike` for Python repos that manage their own dependencies via their project's virtual environment. |

## Permissions

- `contents: write` (required for pushing to the `gh-pages` branch)

## Behavior

1. **Configure git identity** — Sets the git user to `github-actions[bot]` for
   the deploy commit. Marks the workspace as a safe directory to avoid
   dubious-ownership errors in container jobs.
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
   branches, runs `mike deploy --push dev`.

## Reusable workflow

Docs deployment is typically consumed via the `cd-docs.yml` reusable workflow
rather than calling the composite action directly:

```yaml
jobs:
  docs:
    uses: vergil-project/vergil-actions/.github/workflows/cd-docs.yml@v2.1
    permissions:
      contents: write
```

## Examples

### Direct usage (standalone)

```yaml
- uses: vergil-project/vergil-actions/actions/cd/docs/deploy@v2.1
  with:
    version-command: cat VERSION | cut -d. -f1,2
```

### Python repo with uv-managed dependencies

```yaml
- uses: vergil-project/vergil-actions/actions/cd/docs/deploy@v2.1
  with:
    version-command: cat VERSION | cut -d. -f1,2
    mike-command: uv run mike
```

## GitHub configuration

- **GitHub Pages** — Enable GitHub Pages in repository settings with source set
  to **Deploy from a branch** and branch set to `gh-pages`.
- The `gh-pages` branch is created automatically by `mike deploy --push` on
  first run.
