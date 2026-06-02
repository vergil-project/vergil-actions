# ci-docs

Build-only documentation verification workflow. Runs the same staging as the
CD `docs` deploy and then `mkdocs build --strict` — without `mike`, a push, or
any credentials — so documentation that fails to build is caught at PR time
instead of post-merge in the CD `docs` deploy.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `mkdocs-config` | string | no | `docs/site/mkdocs.yml` | Path to the mkdocs configuration file |
| `container-prefix` | string | no | `prod` | Container image name prefix (`prod` or `dev`) |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `build` | `CI Docs / docs` | Stages docs sources and runs a strict mkdocs build |

## Behavior

The `build` job:

1. Checks out the repository with full history (`fetch-depth: 0`) so the
   changelog and release-notes staging can read tags.
2. Detects whether the configured mkdocs config exists. When it is absent the
   remaining steps are skipped and the job passes — repos without docs are
   unaffected, mirroring how `cd-docs` is wired in only for repos that publish
   documentation.
3. Stages changelog and release-notes pages and patches the mkdocs nav using
   the shared `actions/shared/docs/stage` action — the same staging the CD
   `docs` deploy performs, so a green CI docs check reliably predicts a green
   CD docs deploy.
4. Runs `mkdocs build --strict`. The build is credential-free (no `mike`, no
   `--push`, no `id-token`); `--strict` turns nav and reference warnings into
   failures.

For Python repositories the build runs as `uv run mkdocs`; otherwise it runs
`mkdocs` directly, matching the toolchain resolution in
`actions/cd/docs/deploy`.

## Usage

```yaml
jobs:
  docs:
    uses: vergil-project/vergil-actions/.github/workflows/ci-docs.yml@v2.0
```

Add the job only in repositories that publish documentation
(`[publish] docs = true` in `vergil.toml`), the same condition under which
`cd-docs` is wired into `cd.yml`.
