# ops/github-config/branch-sweep

Deletes the branches on a repo whose pull-request work is finished, and lists
every deleted branch in the job summary. It runs
[`vrg-branch-sweep --apply`](https://github.com/vergil-project/vergil-tooling/blob/develop/docs/site/docs/reference/dev/branch-sweep.md)
from vergil-tooling, which decides what counts as finished and what is never
deleted.

This action is the **scheduled safety net** behind the delete-on-merge repo
setting and the delete-on-close rule. It is **wired automatically** into the
`branch-sweep` job of the `ops-github-config.yml` reusable workflow, so every
repo whose `ops.yml` calls that workflow is swept on the same nightly schedule
as its config audit. Consuming repositories do not add it themselves.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ops/github-config/branch-sweep@v2.1
  env:
    GH_TOKEN: ${{ steps.app-token.outputs.token }}
```

The action requires `vergil-tooling` on `PATH` (installed by a preceding
`shared/setup/vergil` step) and a `GH_TOKEN` that can read the repo's pull
requests and delete its branches.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `repo` | No | `${{ github.repository }}` | Repository to sweep, as `OWNER/NAME` |

## Token

`ops-github-config.yml` mints a GitHub App token for this job with only
`contents: write` (to delete the branch ref) and `pull-requests: read` (to
decide which branches are finished). The token is scoped to the calling repo
alone. The workflow's `GITHUB_TOKEN` cannot be used: a called workflow can only
request the permissions the caller grants, and the standard `ops.yml` grants
`contents: read`.

## Job summary

The summary lists each deleted branch with a link to its PR, in two groups:

- **Merged PR, branch not auto-deleted.** The delete-on-merge setting should
  already have removed these. A leftover means GitHub skipped its after-merge
  processing, and the merge may also have fired no push event (the
  vergil-actions #951 case). This group is shown in a warning block, and each
  branch also gets a `::warning::` annotation on the run, so it stands out
  rather than being quietly cleaned up.
- **PR closed without merging.** GitHub never deletes these on its own; the
  sweep is the expected cleanup when the delete-on-close rule missed one.

Errors are listed in a third group. The full `vrg-branch-sweep` output is
included in a collapsed block.

## Failure handling

The step fails, and so does the job, when:

- `vrg-branch-sweep` exits non-zero. A branch that could not be processed, a
  branch list that could not be read, and an authentication failure all count.
  The summary is still written first.
- the per-branch lines cannot be reconciled with the sweep's own summary line
  (the deleted and error counts disagree, or the summary line is missing).
  This guards against a change in `vrg-branch-sweep`'s output format silently
  producing an empty report.

The job does not use `continue-on-error`.

The reporting logic lives in `sweep.sh` so it is unit-testable; see
`actions/ops/github-config/branch-sweep/tests/sweep.test.sh`, run by the
`smoke-branch-sweep.yml` workflow.
