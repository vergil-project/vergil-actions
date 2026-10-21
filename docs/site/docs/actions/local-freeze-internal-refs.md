# local/freeze-internal-refs

Rewrites this repository's internal action and workflow refs to absolute refs
at the release tag, checks that none are left unfrozen, and commits the result.
It runs `vrg-freeze-refs` from vergil-tooling.

This is a **local** action: only this repository's own `cd.yml` uses it, in
the release job on `main`, just before `cd/release/tag-and-release`. It is not
meant for consuming repositories.

## Why

During development the workflows and actions here refer to each other with
relative refs (`./actions/...`, `./.github/workflows/...`) or `@develop`, so a
PR is tested by the code it changes. A consumer that pins `@v2.1.0` must get
the actions from that same release, and a relative ref does not resolve when a
reusable workflow is called from another repository. Freezing the refs at
release time solves both. See
[Reference freezing](../workflows/index.md#reference-freezing).

## Usage

```yaml
- name: Freeze internal refs to release tag
  uses: ./actions/local/freeze-internal-refs
  with:
    tag: ${{ steps.version.outputs.tag }}

- name: Tag and release
  uses: ./actions/cd/release/tag-and-release
  with:
    version: ${{ steps.version.outputs.version }}
```

The action needs `vergil-tooling` on `PATH`.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `tag` | Yes | — | Release tag to freeze to (e.g. `v1.5.20`). |
| `owner-repo` | No | `${{ github.repository }}` | `OWNER/REPO` used to build the absolute refs. |

The action has no outputs.

## Behavior

1. **Configure the git identity** as `github-actions[bot]`.
2. **Freeze and validate.** Runs
   `vrg-freeze-refs --owner-repo <owner-repo> --tag <tag>` over every `.yml`
   and `.yaml` file under `.github/workflows` and `actions`. On each line that
   contains `uses:` it rewrites:

    | From | To |
    | ---- | -- |
    | `./actions/<path>` | `<owner-repo>/actions/<path>@<tag>` |
    | `./.github/workflows/<path>` | `<owner-repo>/.github/workflows/<path>@<tag>` |
    | `<owner-repo>/<path>@develop` | `<owner-repo>/<path>@<tag>` |

    It then fails the step, listing each line in the job summary, if any
    relative or `@develop` ref remains.
3. **Commit.** If anything changed, stages `.github/workflows` and `actions`
   and commits `chore(release): freeze internal refs to <tag>`.

The commit is not pushed to a branch. The `tag-and-release` step that follows
tags `HEAD`, so the frozen refs exist only at the release tag; `develop` and
`main` keep their relative refs.

## Permissions

The step itself only edits and commits locally. Because it changes files under
`.github/workflows`, `cd.yml` checks out with a GitHub App token that has
`workflows: write`: `GITHUB_TOKEN` cannot push a tag whose commit changes
workflow files.
