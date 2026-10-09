# publish-index

`publish-index.yml` is called from an `<org>/packages` repository. Its
`build-index` job runs `vrg-package index --config packages.toml --keys keys
--out _site`, which verifies, retains, indexes and signs the product releases.
Its `deploy` job then publishes the site with the Actions-based Pages deploy.
The workflow takes no inputs. Runs are serialized by the `publish-index`
concurrency group. Unlike the other reusable workflows, it runs directly on
`ubuntu-latest` rather than in a vergil container image.

## Attestation verification

Before indexing, `vrg-package index` verifies every downloaded `.deb` and
`.rpm` with `gh attestation verify`, pinned to the signer workflow
`vergil-project/vergil-actions/.github/workflows/cd-release.yml` and the
source ref `refs/heads/main`. An asset whose build provenance was not attested
by `cd-release.yml` running on a product's `main` branch fails the index
build. Each `.rpm`'s org signature is checked as well.

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
