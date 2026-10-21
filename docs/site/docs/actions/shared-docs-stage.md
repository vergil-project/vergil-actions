# shared/docs/stage

Stages the changelog and release-notes pages into the MkDocs source tree and
patches the MkDocs nav with the release versions. `ci-docs` (the PR-time
strict build) and `cd-docs` (the post-merge deploy) both run this action, so
they build the docs from the same source tree: a green `docs / docs` check
predicts a green docs deploy.

This action is **wired automatically** into `ci-docs` and `cd-docs`. Consuming
repositories do not add it themselves.

## Usage

```yaml
- uses: actions/checkout@v6
  with:
    fetch-depth: 0

- name: Install vergil-tooling
  uses: vergil-project/vergil-actions/actions/shared/setup/vergil@v2.1

- name: Stage documentation sources
  uses: vergil-project/vergil-actions/actions/shared/docs/stage@v2.1
  with:
    mkdocs-config: docs/site/mkdocs.yml
```

The action needs `vergil-tooling` on `PATH` and a checkout with full history
(`fetch-depth: 0`), because the staging reads git tags.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `mkdocs-config` | No | `docs/site/mkdocs.yml` | Path to the MkDocs configuration file. The docs directory is taken to be `docs/` next to it. |

The action has no outputs.

## Behavior

1. **Mark the workspace safe for git.** Runs
   `git config --global --add safe.directory '*'`, because inside a container
   the workspace is owned by a different UID than the user git runs as.
2. **Stage the changelog and release notes.** Runs
   `vrg-docs-stage --docs-dir <docs-dir>`. It links each release page to that
   release's CI-evidence bundle with `gh release view`, so the step sets
   `GH_TOKEN` to the workflow's `github.token`.
3. **Patch the nav.** Runs `vrg-docs-patch-nav` against the MkDocs config and
   `<docs-dir>/releases`, adding the release versions to the nav.

Both steps edit the working tree only; nothing is committed or pushed.

## Permissions

- `contents: read` (enough for `gh release view` on the repository's own
  releases)
