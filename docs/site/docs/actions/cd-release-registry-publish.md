# cd/release/registry-publish

Builds the release for the repository's language ecosystem, optionally attests
the build and generates an SBOM, and, when enabled, publishes to the package
registry. Build and publish commands come from vergil-tooling's ecosystem
metadata (`vrg-ecosystem-resolve`) unless the caller overrides them.

This action is **wired automatically** into the `cd-release` release job, where
its **Build and publish** step runs for `python`, `java`, `rust` and `go`
repositories. Consuming repositories set its behavior through the
`cd-release` inputs and secrets, not by calling it directly.

## Usage

```yaml
- name: Build and publish
  uses: vergil-project/vergil-actions/actions/cd/release/registry-publish@v2.1
  with:
    language: python
    version: ${{ steps.version.outputs.version }}
    registry-publish: "true"
    attestation-subject-path: dist/*
    sbom-output-file: sbom-$VERSION.cdx.json
```

The action needs `vergil-tooling` on `PATH`.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `language` | Yes | — | Primary language. Selects the ecosystem build and publish commands. |
| `version` | Yes | — | Semver version string (e.g. `1.2.3`). Exported as `VERSION` to the build and publish commands. |
| `registry-publish` | No | `"false"` | `"true"` runs the publish step. |
| `build-command` | No | `""` | Replaces the ecosystem build command. |
| `publish-command` | No | `""` | Replaces the ecosystem publish command. |
| `attestation-subject-path` | No | `""` | Glob of build outputs to attest with `actions/attest-build-provenance`. Empty skips attestation. |
| `sbom-output-file` | No | `""` | SBOM output path; `$VERSION` is replaced with the version. Empty skips the SBOM. |
| `cargo-registry-token` | No | `""` | Rust: crates.io token. Exported as `CARGO_REGISTRY_TOKEN`, which `cargo publish` reads. |
| `central-username` | No | `""` | Java: Maven Central username. Exported as `MAVEN_USERNAME`. |
| `central-token` | No | `""` | Java: Maven Central token. Exported as `MAVEN_PASSWORD`. |
| `gpg-private-key` | No | `""` | Java: GPG signing key. |
| `gpg-passphrase` | No | `""` | Java: GPG passphrase. Exported as `MAVEN_GPG_PASSPHRASE`, which `maven-gpg-plugin` reads. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `build-command` | The build command used (derived or overridden). |
| `publish-command` | The publish command used (derived or overridden). |
| `sbom-output-file` | The SBOM path with `$VERSION` replaced; empty when no SBOM was requested. |

## Ecosystem commands

The derived commands come from vergil-tooling's language registry:

| Language | Build | Publish | Credential variable |
| -------- | ----- | ------- | ------------------- |
| `python` | `uv build` | `uv publish` | none (PyPI trusted publishing) |
| `java` | `./mvnw package -B` | `./mvnw deploy -B` | `MAVEN_GPG_PASSPHRASE` |
| `rust` | `cargo build --release` | `cargo publish` | `CARGO_REGISTRY_TOKEN` |
| `go` | `go build ./...` | none | none |

## Behavior

1. **Derive commands.** Runs `vrg-ecosystem-resolve <language>`, which sets
   `build`, `publish` and `credential-secret` step outputs, then replaces
   `build` or `publish` with `build-command` / `publish-command` when given.
   An unsupported language fails the step.
2. **Configure Maven credentials** (`java` only). Writes `~/.m2/settings.xml`
   with a `central` server that reads `MAVEN_USERNAME` / `MAVEN_PASSWORD`,
   and imports `gpg-private-key` when set.
3. **Resolve version placeholders.** Replaces `$VERSION` in
   `sbom-output-file`.
4. **Build.** Creates `dist/`, then runs the build command with `VERSION` set.
   Skipped when there is no build command.
5. **Attest build provenance.** Runs `actions/attest-build-provenance` on
   `attestation-subject-path`. Skipped when it is empty.
6. **Generate SBOM.** Runs [`shared/security/trivy`](shared-security-trivy.md)
   with `scan-type: sbom`. Skipped when `sbom-output-file` is empty.
7. **Publish.** Runs only when `registry-publish` is `"true"` and there is a
   publish command. The step sets `CARGO_REGISTRY_TOKEN`, `MAVEN_USERNAME`,
   `MAVEN_PASSWORD` and `MAVEN_GPG_PASSPHRASE` from the inputs, then runs
   `publish.sh`. When the ecosystem names a credential variable and that
   variable is empty, the step fails with an `::error::` naming the
   `cd-release` secret to set (or telling you to turn `registry-publish`
   off): `CARGO_REGISTRY_TOKEN` comes from the `CARGO_REGISTRY_TOKEN` secret
   and `MAVEN_GPG_PASSPHRASE` from the `GPG_PASSPHRASE` secret. A requested
   publish that cannot happen never lets the release report success. A
   credential variable this action does not set also fails the step, since
   it means vergil-tooling and vergil-actions disagree on the name. Python
   names no credential: `uv publish` uses PyPI trusted publishing, which
   needs `id-token: write` and a trusted publisher configured for the
   project on PyPI.

## Permissions

- `contents: read` to build
- `id-token: write` and `attestations: write` when `attestation-subject-path`
  is set
- `id-token: write` to publish a `python` release (PyPI trusted publishing)
