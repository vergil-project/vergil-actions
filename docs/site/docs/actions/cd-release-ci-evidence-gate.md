# cd/release/ci-evidence-gate

The pre-publish CI-evidence gate. It finds the release PR, downloads the
`ci-evidence-<gate>` artifacts its CI produced (see
[`ci/evidence/emit`](ci-evidence-emit.md)), and checks that every required
gate's evidence is present and complete. It runs **before** anything is
published, so in enforcing mode no package, tag or Release is created without
complete evidence.

It does not build, attest or attach anything: at this point the GitHub Release
does not exist and the SBOM is not built.
[`cd/release/ci-evidence-attach`](cd-release-ci-evidence-attach.md) does that
after `tag-and-release`, from the evidence this action downloaded.

This action is **wired automatically** into the `cd-release` release job.
Consuming repositories do not add it themselves; they choose the mode with the
`cd-release` input `evidence-enforce`.

## Usage

```yaml
- name: CI evidence gate (pre-publish)
  id: evidence_gate
  continue-on-error: ${{ !inputs.evidence-enforce }}
  uses: vergil-project/vergil-actions/actions/cd/release/ci-evidence-gate@v2.1
  with:
    version: ${{ steps.version.outputs.version }}
    enforce: ${{ inputs.evidence-enforce }}
```

The action needs `vergil-tooling` on `PATH`.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `version` | Yes | — | Semver version string (e.g. `2.1.129`). |
| `enforce` | No | `"true"` | `"true"` (enforcing): a failure or timeout fails the step, before publish. `"false"` (warning): it emits a `::warning::` and the step succeeds. Warning mode is a temporary opt-out, not a permanent soft gate. |
| `timeout-minutes` | No | `"15"` | Upper bound on the harvest, enforced with the coreutils `timeout` command (composite steps cannot use `timeout-minutes`). A timeout counts as a gate failure. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `passed` | `"true"` only when the harvest exited 0. Empty on any failure or timeout, in either mode. |

## Behavior

The action runs one step:

```bash
timeout "${TIMEOUT_MINUTES}m" vrg-ci-evidence harvest \
  --repo "$GITHUB_REPOSITORY" \
  --merge-sha "$GITHUB_SHA" \
  --out-dir "$GITHUB_WORKSPACE/.ci-evidence-staging"
```

`vrg-ci-evidence harvest` resolves the release PR from the merge commit,
downloads the required gate artifacts, validates them, and exits non-zero
when a required gate is missing or incomplete. It leaves the downloaded
evidence and a `harvest-state.json` in `.ci-evidence-staging`, which
`ci-evidence-attach` reads later, so the artifacts are downloaded once.

On success the step writes `passed=true`. On failure it reports
`failed (exit <rc>)` or `timed out after <n>m`, then exits with the tool's
code in enforcing mode, or exits 0 with a warning in warning mode.

## Enforcement in cd-release

`cd-release` does not rely on the step's exit code alone. A plain
**Enforce CI evidence gate** step follows it and fails the job when, in
enforcing mode, the gate step's outcome is `failure` or it succeeded without
`passed=true`. So a gate failure cannot be masked into a green step (#925).
See [All Hard Gates](../ci-gates/all-hard-gates.md#example-the-ci-evidence-gate).

## Permissions

- `actions: read`, to list and download the release PR's `ci-evidence-*`
  artifacts from its CI run. A reusable workflow's permissions are capped by
  the caller, so the consuming repository's `cd.yml` must grant it too.
- `contents: read` (the `cd-release` release job grants `contents: write` for
  its other steps).

The step authenticates with the workflow's `github.token`.
