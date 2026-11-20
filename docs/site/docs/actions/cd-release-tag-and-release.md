# cd/release/tag-and-release

Creates an annotated git tag and a GitHub Release. All mutating steps are
skipped when the tag already exists, making the action safe to re-run. Every
tag push uses the automation App's installation token passed as `tag-token`,
never the checkout's `GITHUB_TOKEN`.

!!! note "Rolling minor tags"
    Rolling minor tags (e.g. `v1.2`) are no longer created by this action.
    They are now managed by `vrg-promote` in the release orchestrator's
    `promote` phase.

## Usage

```yaml
- name: Mint release tag token
  id: tag_token
  uses: actions/create-github-app-token@v3
  with:
    app-id: ${{ secrets.APP_CLIENT_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
    repositories: ${{ github.event.repository.name }}
    permission-contents: write

- uses: vergil-project/vergil-actions/actions/cd/release/tag-and-release@v2.1
  with:
    version: "1.2.3"
    tag-token: ${{ steps.tag_token.outputs.token }}
    release-title: mqrestadmin
    release-notes: "Release notes markdown here"
    release-artifacts: ""
    tag-prefix: v
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `version` | **Yes** | — | Semver version string (e.g. `1.2.3`). |
| `tag-token` | **Yes** | — | The automation App's installation token, with Contents write on this repository, that every tag push uses. The action fails before tagging when it is empty. |
| `release-title` | No | `<repo-name> v<version>` | Release title override. |
| `release-notes` | No | A link to the GitHub Pages site | Release notes override. |
| `release-artifacts` | No | `""` | Space-separated glob of files to attach to the GitHub Release. Leave empty for no artifacts. |
| `tag-prefix` | No | `v` | Prefix prepended to the version to form the git tag. |

## Outputs

| Name | Description |
| ------ | ------------- |
| `tag` | The full tag name that was (or would be) created (e.g. `v1.2.3`). |
| `tag-created` | `true` if a new tag was created, `false` if it already existed. |

## Permissions

- `contents: write` on the job's `GITHUB_TOKEN`, which creates the GitHub
  Release.
- Contents write on the App token passed as `tag-token`, which pushes the
  tags. A tag whose commit changes `.github/workflows/` files that are not
  yet on the remote also needs Workflows write (vergil-actions' own
  `cd.yml`, whose release commit freezes its internal refs).

## Behavior

1. **Compute tag name** — Concatenates `tag-prefix` and `version` (e.g.
   `v` + `1.2.3` = `v1.2.3`).
2. **Check existing tag** — If the tag already exists, all subsequent steps are
   skipped (idempotent re-run).
3. **Require the tag token** — Fails, with nothing tagged, when `tag-token` is
   empty.
4. **Configure git identity** — Sets the git user to `github-actions[bot]`.
5. **Create annotated tag** — Creates `v<version>` with message
   `Release <version>` and pushes it with the App token.
6. **Create GitHub Release** — Uses `gh release create` with the job's
   `GITHUB_TOKEN`, the provided title and notes, and optional artifacts.
7. **Verify tag is resolvable from remote** — Clones the tag back from
   GitHub. If that fails, the tag reached the remote with missing objects:
   it is re-pushed whole with the App token and cloned again.

Every push goes through the action's `push-tag.sh`. `actions/checkout`
leaves its token in the repository's git config as an
`http.<server>/.extraheader` Authorization header, and git sends every value
of that key. The script resets that list and sets the App token's header,
as command-line git config, so the push authenticates as the App alone.

## Examples

### Standard library release

```yaml
- uses: vergil-project/vergil-actions/actions/cd/release/tag-and-release@v2.1
  with:
    version: ${{ steps.version.outputs.version }}
    tag-token: ${{ steps.tag_token.outputs.token }}
    release-title: mqrestadmin
    release-notes: ${{ steps.changelog.outputs.notes }}
```

### Release with build artifacts

```yaml
- uses: vergil-project/vergil-actions/actions/cd/release/tag-and-release@v2.1
  with:
    version: "2.0.0"
    tag-token: ${{ steps.tag_token.outputs.token }}
    release-title: myapp
    release-notes: "## What's New\n\nInitial v2 release."
    release-artifacts: "dist/*.tar.gz dist/*.whl"
```

## GitHub configuration

- **Tag protection** — The Tag protection ruleset restricts the creation,
  update and deletion of release tags to the repository Admin role and the
  automation App (creation since epic
  [vergil-project/.github#1350](https://github.com/vergil-project/.github/issues/1350)).
  So the tags are pushed as the App, which needs Contents write on the
  repository; see
  [APP_CLIENT_ID and APP_PRIVATE_KEY](../configuration.md#app_client_id-and-app_private_key).
