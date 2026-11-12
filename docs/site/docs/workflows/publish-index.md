# publish-index

`publish-index.yml` is called from an `<org>/packages` repository. Its
`build-index` job runs `vrg-package index --config packages.toml --keys keys
--out _site`, which verifies, retains, indexes and signs the product releases.
Its `deploy` job then publishes the site with the Actions-based Pages deploy.
Last, it checks that Pages serves the index this run built (below).
The workflow takes no inputs. Runs are serialized by the `publish-index`
concurrency group. Unlike the other reusable workflows, it runs directly on
`ubuntu-24.04` rather than in a vergil container image.

## Attestation verification

Before indexing, `vrg-package index` verifies every downloaded `.deb` and
`.rpm` with `gh attestation verify`, pinned to the signer workflow
`vergil-project/vergil-actions/.github/workflows/cd-release.yml` and the
source ref `refs/heads/main`. An asset whose build provenance was not attested
by `cd-release.yml` running on a product's `main` branch fails the index
build. Each `.rpm`'s org signature is checked as well.

## Post-deploy live check

GitHub Pages can report a deployment `success` while it goes on serving the
previous deployment
([vergil-project/packages#46](https://github.com/vergil-project/packages/issues/46)).
So `build-index` records the sha256 of every signed `InRelease` and
`repomd.xml` it built. After the deploy, `deploy` fetches each of those files
from the deployment's `page_url`, with a cache-busting query string, until all
of them match. If they still do not match after about five minutes, the job
fails with an `::error::` that names the run and shows what was served. Re-run
the workflow; if the fault repeats, raise it with GitHub Support. See
[publish/index/live-check](../actions/publish-index-live-check.md).

## Caller requirements

- **Pages source set to "GitHub Actions".** The `deploy` job publishes with
  `actions/deploy-pages`, so the caller repository's **Settings > Pages >
  Build and deployment > Source** must be **GitHub Actions**, not "Deploy from
  a branch".
- **An `index-signing` environment** (below).
- **`secrets: inherit`** and the job permissions shown in the example.

## Signing environment and caller example

The signing key comes from the caller repository's `index-signing`
environment, which must admit only `develop` and hold `PACKAGE_SIGNING_KEY`
and `PACKAGE_SIGNING_PASSPHRASE`. As with `cd-release`, those environment
secrets reach the reusable workflow only when the caller passes
`secrets: inherit` (see [cd-release: binary packages](cd-release-packages.md)).
The caller must also grant the scopes the two jobs request:

```yaml
jobs:
  publish-index:
    uses: vergil-project/vergil-actions/.github/workflows/publish-index.yml@v2.1
    permissions:
      contents: read
      attestations: read
      pages: write
      id-token: write
    # Required: environment secrets only reach the reusable workflow with inherit.
    secrets: inherit  # nosemgrep: yaml.github-actions.security.secrets-inherit.secrets-inherit
```
