# cd/release/ci-evidence-attach

The post-publish CI-evidence step. It assembles the evidence bundle from what
[`cd/release/ci-evidence-gate`](cd-release-ci-evidence-gate.md) downloaded,
adds the SBOM built earlier in the job, attests the bundle, and attaches it to
the GitHub Release. It runs **after** `tag-and-release`, because both the
Release (the upload target) and the SBOM (bundle content) exist only then.

This action is **wired automatically** into the `cd-release` release job.
Consuming repositories do not add it themselves; they choose the mode with the
`cd-release` input `evidence-enforce`.

## Usage

```yaml
- name: Attach CI evidence bundle (post-release)
  id: evidence_attach
  continue-on-error: ${{ !inputs.evidence-enforce }}
  uses: vergil-project/vergil-actions/actions/cd/release/ci-evidence-attach@v2.1
  with:
    version: ${{ steps.version.outputs.version }}
    tag: ${{ steps.version.outputs.tag }}
    enforce: ${{ inputs.evidence-enforce }}
    sbom-file: ${{ steps.evidence_sbom.outputs.path }}
```

The action needs `vergil-tooling` on `PATH` and the
`.ci-evidence-staging` directory that `ci-evidence-gate` left in the workspace
earlier in the same job.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `version` | Yes | — | Semver version string (e.g. `2.1.129`). |
| `tag` | Yes | — | Release tag the bundle is attached to (e.g. `v2.1.129`). |
| `enforce` | No | `"true"` | `"true"` (enforcing): a bundling or upload failure fails the step. `"false"` (warning): it emits a `::warning::` and the step succeeds. Warning mode is a temporary opt-out, not a permanent soft gate. |
| `timeout-minutes` | No | `"15"` | Upper bound on the assemble step, enforced with the coreutils `timeout` command. A timeout counts as a bundling failure. |
| `sbom-file` | No | `""` | Path to the SBOM that `registry-publish` built. Included when the file exists; when it is set but missing, the step logs a notice and bundles without it. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `attached` | `"true"` only when the bundle was assembled, attested and uploaded to the Release. Empty on any failure, in either mode. |

## Behavior

1. **Assemble.** Runs `vrg-ci-evidence assemble` with `--staging`
   `.ci-evidence-staging`, the version, a UTC `--generated-at` timestamp and
   `--sbom-file` when the SBOM exists. The command makes no network calls: it
   builds the tarball and a standalone manifest in `evidence-out/` from the
   evidence already downloaded. On failure it reports `failed (exit <rc>)` or
   `timed out after <n>m` and exits with that code in enforcing mode, or 0 with
   a warning in warning mode.
2. **Attest.** Runs `actions/attest-build-provenance` on
   `evidence-out/*.tar.gz`. Skipped when assembly failed.
3. **Attach.** Runs
   `gh release upload <tag> evidence-out/*.tar.gz evidence-out/*-manifest.json --clobber`
   and writes `attached=true` on success. A failed upload is fatal in
   enforcing mode and a warning in warning mode. Skipped when assembly failed.

The attest step is a `uses:` step, so the shell's warning-mode handling cannot
catch its failure. `cd-release` covers that with
`continue-on-error: ${{ !inputs.evidence-enforce }}` on the calling step.

## Enforcement in cd-release

A plain **Enforce CI evidence attach** step follows this one and, in enforcing
mode, fails the job when the attach step's outcome is `failure` or it
succeeded without `attached=true` (#925). By then the tag and Release are
already published, so its error says the release is missing its evidence
bundle and needs operator attention.

## Permissions

- `contents: write` (to upload Release assets)
- `id-token: write` and `attestations: write` (for the provenance attestation)
