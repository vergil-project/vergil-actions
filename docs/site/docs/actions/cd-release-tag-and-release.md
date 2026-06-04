# publish/tag-and-release

Creates an annotated git tag, a develop changelog boundary tag, and a GitHub
Release. All mutating steps are skipped when the tag already exists, making the
action safe to re-run.

!!! note "Rolling minor tags"
    Rolling minor tags (e.g. `v1.2`) are no longer created by this action.
    They are now managed by `vrg-promote` in the release orchestrator's
    `promote` phase.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/cd/release/tag-and-release@v2.1
  with:
    version: "1.2.3"
    release-title: mqrestadmin
    release-notes: "Release notes markdown here"
    release-artifacts: ""
    tag-prefix: v
```

## Inputs

| Name | Required | Default | Description |
| ------ | ---------- | --------- | ------------- |
| `version` | **Yes** | — | Semver version string (e.g. `1.2.3`). |
| `release-title` | **Yes** | — | Release title prefix (e.g. `mqrestadmin`, `pymqrest`). |
| `release-notes` | **Yes** | — | Full markdown body for the GitHub Release. |
| `release-artifacts` | No | `""` | Space-separated glob of files to attach to the GitHub Release. Leave empty for no artifacts. |
| `tag-prefix` | No | `v` | Prefix prepended to the version to form the git tag. |

## Outputs

| Name | Description |
| ------ | ------------- |
| `tag` | The full tag name that was (or would be) created (e.g. `v1.2.3`). |
| `tag-created` | `true` if a new tag was created, `false` if it already existed. |

## Permissions

- `contents: write` (required for creating tags and releases)

## Behavior

1. **Compute tag name** — Concatenates `tag-prefix` and `version` (e.g.
   `v` + `1.2.3` = `v1.2.3`).
2. **Check existing tag** — If the tag already exists, all subsequent steps are
   skipped (idempotent re-run).
3. **Configure git identity** — Sets the git user to `github-actions[bot]`.
4. **Create annotated tag** — Creates and pushes `v<version>` with message
   `Release <version>`.
5. **Tag develop for changelog boundaries** — Fetches `develop` and creates a
   `develop-v<version>` tag pointing at `origin/develop`, then pushes it. This
   enables changelog generation between releases.
6. **Create GitHub Release** — Uses `gh release create` with the provided title,
   notes, and optional artifacts.

## Examples

### Standard library release

```yaml
- uses: vergil-project/vergil-actions/actions/cd/release/tag-and-release@v2.1
  with:
    version: ${{ steps.version.outputs.version }}
    release-title: mqrestadmin
    release-notes: ${{ steps.changelog.outputs.notes }}
```

### Release with build artifacts

```yaml
- uses: vergil-project/vergil-actions/actions/cd/release/tag-and-release@v2.1
  with:
    version: "2.0.0"
    release-title: myapp
    release-notes: "## What's New\n\nInitial v2 release."
    release-artifacts: "dist/*.tar.gz dist/*.whl"
```

## GitHub configuration

- **Branch protection** — The `GITHUB_TOKEN` must have permission to push tags.
  If tag protection rules are configured, ensure the workflow token is allowed.
