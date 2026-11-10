# publish/index/live-check

Proves that GitHub Pages serves the package index the current run built. Pages
can report a deployment `success`, and mark it active, while its origin goes
on serving the previous deployment
([vergil-project/packages#46](https://github.com/vergil-project/packages/issues/46)).
Without this check the fault surfaced only an hour later, in `vrg-release`'s
`package-index` stage.

This action is **wired automatically** into both jobs of
[`publish-index.yml`](../workflows/publish-index.md). Consuming repositories do
not add it themselves.

## Usage

```yaml
# build-index, after `vrg-package index --out _site`
- id: manifest
  uses: vergil-project/vergil-actions/actions/publish/index/live-check@v2.1
  with:
    mode: manifest
    site: _site

# deploy, after actions/deploy-pages
- uses: vergil-project/vergil-actions/actions/publish/index/live-check@v2.1
  with:
    mode: verify
    base-url: ${{ steps.deployment.outputs.page_url }}
    manifest: ${{ needs.build-index.outputs.index-manifest }}
```

## Inputs

| Input | Default | Description |
| ----- | ------- | ----------- |
| `mode` | (required) | `manifest` or `verify`. Any other value fails. |
| `site` | `_site` | `manifest`: the built site directory. |
| `base-url` | `""` | `verify`: the deployed site's base URL, the `page_url` output of `actions/deploy-pages`. An empty value fails. |
| `manifest` | `""` | `verify`: the `manifest` output of a `mode: manifest` run. |
| `attempts` | `"30"` | `verify`: rounds of fetches before failing. |
| `interval` | `"10"` | `verify`: seconds between rounds. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `manifest` | `manifest`: one `<sha256> <path>` line per signed `InRelease` and per `repomd.xml` in the site, with the path relative to the site root. |

## What identifies the built index

The manifest holds the sha256 of every `deb/dists/<suite>/InRelease` and
every `rpm/<el>/<arch>/repodata/repomd.xml`. Each `InRelease` is signed at
build time and carries the build's `Date:` line, so no two builds share one.
The manifest step fails if the site holds no `InRelease`, since nothing would
then identify the build.

## The verify loop

Each round fetches every file not yet confirmed live from
`<base-url>/<path>?vrg-live-check=<time>-<round>-<random>`, sending
`Cache-Control: no-cache` and `Pragma: no-cache`. A file is live once it is
served with HTTP 200 and its manifest digest. The step passes as soon as all
files are live. A fetch error, a non-200 status or a wrong digest is retried
until the window runs out: 30 rounds 10 seconds apart, about five minutes.
The step then prints one `::error::` per file still wrong. Each one names the
deployment (repository, run ID and attempt), the URL, the expected digest and
what was served, with its HTTP status, digest, `Last-Modified` and `X-Cache`.
A final `::error::` says Pages is likely serving an older deployment and
recommends a re-run, or a GitHub Support ticket if the fault repeats.

A malformed or empty manifest, a path containing `..`, or a bad `attempts` or
`interval` value fails at once, before any fetch.

## Testing

`tests/live-check.test.sh` is a framework-free harness that runs the script
against a fake `curl` and `sleep`. It covers the manifest, every verify
outcome, cache busting and the wiring in `publish-index.yml`. The
`smoke-publish-index` workflow runs it on pull requests.
