# cd-release

The release pipeline. On a push to `main` it checks the CI evidence of the
release PR, builds and publishes the release, tags it and creates the GitHub
Release. Repos with `[package]` in `vergil.toml` also build, sign and attach
`.deb`/`.rpm` packages ([binary packages](cd-release-packages.md)).

## Container image

The `release` job runs in
`ghcr.io/vergil-project/<prefix>-<suffix>:<tag>`:

- `<prefix>` is `container-prefix` (default `prod`).
- `<suffix>` and `<tag>` are the resolver's image suffix and tag for the
  primary version (`[ci].primary-version`, or the newest resolved version),
  the same image CI's primary leg runs on. The `setup` job runs the shared
  [setup action](../actions/shared-setup-vergil.md), which calls
  `vrg-ci-resolve` against the consumer's `vergil.toml` and the published
  language version window. The tag is its `primary-container-tag`; the suffix
  is the primary version's entry in its `container-suffixes`, picked by
  [shared/setup/primary-suffix](../actions/shared-setup-primary-suffix.md).

For example `clang-20` gives `prod-cpp-clang:20`, `node-24` gives
`prod-ts-node:24`, `3.14` gives `prod-python:3.14` and a language-less repo's
`latest` gives `prod-base:latest`.

So a release builds and tests on the image CI resolves today, not on a tag
written into the caller's `cd.yml` when the repo was initialized, or a suffix
guessed from `language` (`language: cpp` used to name `prod-cpp`, which is not
published). The caller passes no tag, and needs no `container-suffix`. If it
passes one, the value must equal the resolved suffix, or `setup` fails: the
caller's `cd.yml` and `vergil.toml` disagree on the language. A resolver error
fails `setup` too, and `release` does not run.

## Inputs

| Input | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `language` | string | `""` | Language ecosystem (`go`, `java`, `python`, `rust`). Omit it for repos with no language. |
| `container-suffix` | string | `""` | Cross-check only. The image suffix comes from the resolver. A non-empty value must equal the resolved primary suffix (e.g. `python`, `cpp-clang`, `base`), or `setup` fails. It never changes the image. |
| `container-tag` | string | `""` | **Deprecated and ignored.** The tag comes from the resolver. A non-empty value only adds a `::warning::` to the run. The input is kept for one release so callers that still pass it do not fail: GitHub rejects a reusable-workflow call that passes an input the workflow does not declare. It is deleted once [vergil-tooling#3484](https://github.com/vergil-project/vergil-tooling/issues/3484) removes it from every caller. |
| `container-prefix` | string | `prod` | Image name prefix (`prod` or `dev`). |
| `registry-publish` | boolean | `false` | Publish build artifacts to the language's package registry. |
| `build-command` | string | `""` | Override the ecosystem's build command. |
| `publish-command` | string | `""` | Override the ecosystem's publish command. |
| `attestation-subject-path` | string | `""` | Glob for build provenance attestation. Empty skips it. |
| `sbom-output-file` | string | `""` | SBOM output path (`$VERSION` placeholder). Empty skips it. |
| `release-artifacts` | string | `""` | Files to attach to the Release (`$VERSION` placeholder). |
| `evidence-enforce` | boolean | `true` | `true` fails the release before publish when the CI evidence is incomplete or failed. `false` only warns, as a temporary per-repo opt-out. |

## Jobs

| Job | Behavior |
| --- | -------- |
| `setup` | Always runs. Resolves `primary-container-suffix` and `primary-container-tag` for `release`, fails if the caller's `container-suffix` disagrees with the resolved suffix, and warns if the caller passed `container-tag`. |
| `package-matrix` | Always runs. Resolves the package build cells; a repo without `[package]` reports none. See [binary packages](cd-release-packages.md). |
| `package-build / <cell>`, `package-sign` | Packaged repos only. See [binary packages](cd-release-packages.md). |
| `release` | Runs when `setup` and `package-matrix` succeeded, and `package-sign` too for a packaged repo. Validates the inputs, gates on the CI evidence, publishes, tags and releases, then attaches the evidence bundle. |

## Usage

```yaml
jobs:
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
      registry-publish: true
```

The caller's `permissions:` must include `actions: read` (the evidence gate
downloads the release PR's CI evidence artifacts), `contents: write`,
`id-token: write` and `attestations: write`. A packaged repo must pass
`secrets: inherit`; see [binary packages](cd-release-packages.md).
