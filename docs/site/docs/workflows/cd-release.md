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
| `language` | string | `""` | Language ecosystem (`go`, `python`, `rust`, `typescript`). Omit it for repos with no language. |
| `container-suffix` | string | `""` | Cross-check only. The image suffix comes from the resolver. A non-empty value must equal the resolved primary suffix (e.g. `python`, `cpp-clang`, `base`), or `setup` fails. It never changes the image. |
| `container-tag` | string | `""` | **Deprecated and ignored.** The tag comes from the resolver. A non-empty value only adds a `::warning::` to the run. The input is kept for one release so callers that still pass it do not fail: GitHub rejects a reusable-workflow call that passes an input the workflow does not declare. It is deleted once [vergil-tooling#3484](https://github.com/vergil-project/vergil-tooling/issues/3484) removes it from every caller. |
| `container-prefix` | string | `prod` | Image name prefix (`prod` or `dev`). It picks the `release` job's image and, for repos with `[package]`, the `<prefix>-pkg-*` images of the `package-build` cells ([binary packages](cd-release-packages.md#container-prefix)). |
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
| `package-build / <cell>`, `package-sign` | Packaged repos only. Every cell builds on the runtime `package-matrix` recorded, and `package-sign` checks every package against it before signing. See [binary packages](cd-release-packages.md). |
| `release` | Runs when `setup` and `package-matrix` succeeded, and `package-sign` too for a packaged repo. Validates the inputs, gates on the CI evidence, publishes, tags and releases, then attaches the evidence bundle. |

## Re-running a published release

A re-run of the `release` job after its tag exists never moves or
recreates the tag and never publishes again: the secrets check, the token
mint, the package and registry steps, `Tag and release` and the package
index dispatch all run only for a new tag.

The CI evidence bundle is checked instead. The `Check the release's CI
evidence` step reads the existing GitHub Release's assets:

- When it carries both `v<version>-ci-evidence.tar.gz` and
  `v<version>-ci-evidence-manifest.json`, the evidence steps are skipped
  and the job succeeds with a notice.
- When either is missing (an earlier attempt failed after `Tag and
  release`, for example at the bundle's provenance attestation), the
  evidence gate, the attach with its attestation and both enforcement
  guards run as on a new release, with a warning naming the missing
  assets. With `evidence-enforce: true`, the job fails if the bundle
  cannot be gated or attached. A configured SBOM is taken from the
  Release's assets, since a re-run builds nothing; if it is not one, the
  bundle is assembled without it, with a warning.
- When the Release cannot be read, the job fails, naming the tag.

Only a run on the tagged commit counts as a re-run. When the tag is on
another commit (a push to `main` with no version bump), the job attaches
nothing to that older release, since this commit's evidence is not its
own, and succeeds with a notice.

## Usage

```yaml
jobs:
  release:
    if: github.ref == 'refs/heads/main'
    uses: vergil-project/vergil-actions/.github/workflows/cd-release.yml@v2.1
    with:
      language: python
      registry-publish: true
    secrets: inherit
```

A caller in vergil-project passes `secrets: inherit`; a caller in another
org passes the secrets by name (see [Secrets](#secrets)). The caller's `permissions:` must include `actions: read` (the evidence gate
downloads the release PR's CI evidence artifacts), `contents: write`,
`id-token: write` and `attestations: write`. A packaged repo must pass
`secrets: inherit`; see [binary packages](cd-release-packages.md).

## Secrets

| Secret | Required | Description |
| ------ | -------- | ----------- |
| `APP_CLIENT_ID` | yes | Client ID of the org's automation GitHub App ([APP_CLIENT_ID and APP_PRIVATE_KEY](../configuration.md#app_client_id-and-app_private_key)) |
| `APP_PRIVATE_KEY` | yes | Private key of the same App |
| `CARGO_REGISTRY_TOKEN` | Rust registry publish only | crates.io token for `registry-publish` |

Both App secrets live in the calling repository's `automation` environment.
Only the `release` job declares `environment: automation` and reads them; a
packaged release's `package-sign` job declares `package-signing` instead
(see [binary packages](cd-release-packages.md)).

Every release needs the two App secrets. The `release` job pushes the
`v<version>` tag with the App's installation token, never its
`GITHUB_TOKEN`, so that the Tag protection ruleset can let only the
repository Admin role and the App create a release tag. The token
is scoped to the calling repository with Contents write only. A packaged
release also uses the App to dispatch the package index.

The workflow declares both App secrets optional, so a caller that does not
pass them still runs. Its `release` job then fails at its first release
step, `Require the automation App secrets`, with an error naming each
missing secret, before the evidence gate, the registry publish or any tag.

A calling job cannot declare an environment, so the caller passes the
secrets on by one of two routes, as `vrg-github-repo-init` generates it.
Within vergil-project it passes `secrets: inherit`, which carries the App
keys, `CARGO_REGISTRY_TOKEN` and a packaged repo's signing secrets.
vrg-validate's secrets-inherit check allows it only to the App-key
workflows:

```yaml
    secrets: inherit
```

GitHub passes `secrets: inherit` only to a reusable workflow in the
caller's own organization or enterprise, so a caller in another org passes
the keys by name, adding `CARGO_REGISTRY_TOKEN` for a Rust registry
publish:

```yaml
    # By name, not inherit: GitHub passes `secrets: inherit` only to a
    # reusable workflow in the caller's own organization or enterprise.
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

A packaged repo outside vergil-project cannot sign its packages yet
([vergil-project/.github#1592](https://github.com/vergil-project/.github/issues/1592)).

## Variables

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `VRG_TRUSTED_AUTHORS` | yes | Org-level Actions variable holding the trusted-authors configuration, published with `vrg-trusted-authors publish` (see [VRG_TRUSTED_AUTHORS](../configuration.md#vrg_trusted_authors)). Passed to the `package-matrix` job's `Refuse re-publishing a released package version` step and to the `release` job's [CI evidence gate](../actions/cd-release-ci-evidence-gate.md), which stop when it is missing or invalid |

A release run before the variable is published fails at one of those
steps, before anything is published or tagged; re-run it once the variable
is published.
