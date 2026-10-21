# shared/setup/vergil

Installs `vergil-tooling` at the version the repository pins in `vergil.toml`,
and derives the repository's CI version set from the same file. Reusable
workflows read their version matrix and container tags from this action's
outputs instead of from hard-coded inputs.

This action is **wired automatically** into the reusable workflows: every job
that runs a `vrg-*` command, and the `matrix` and `setup` jobs that resolve the
version set. Consuming repositories do not add it themselves. It is documented
here for operators who need to understand what the step does and why a job
might fail inside it.

## Usage

```yaml
- uses: actions/checkout@v6

- name: Install vergil-tooling
  id: setup
  uses: vergil-project/vergil-actions/actions/shared/setup/vergil@v2.1
  with:
    language: python   # optional; only affects primary-container-tag
```

The repository must be checked out first: the action reads `vergil.toml` (and,
to detect vergil-tooling itself, `pyproject.toml`) from the working directory.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `language` | No | `""` | Primary language of the calling repository (e.g. `python`, `cpp`, `shell`). Used only to family-route `primary-container-tag` for `cpp` and `typescript`. When omitted, `primary-container-tag` is the primary version unchanged. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `versions` | `[ci].versions` from `vergil.toml` as a compact JSON array string, e.g. `["3.12","3.13","3.14"]`. The `matrix` job passes it to [`ci/matrix`](https://github.com/vergil-project/vergil-actions/blob/develop/actions/ci/matrix/action.yml) to fan out per-version legs. |
| `primary-version` | `[ci].primary-version` when it is set; otherwise the highest entry in `[ci].versions` by natural sort (`3.14` from `["3.12","3.13","3.14"]`, `clang-20` over `clang-9`). |
| `primary-container-tag` | The container tag of the primary version. For `cpp` and `typescript` the family prefix is dropped (`clang-20` becomes `20`, `node-24` becomes `24`), the same split `ci/matrix` applies to each matrix leg; for every other language it is the primary version unchanged. Used by the single-container `common` job in `ci-quality` and the `version-bump` job in `ci-version-bump`. |

## Behavior

The action runs these steps in order:

1. **Mark the workspace safe for git.** Adds the workspace to git's
   `safe.directory` list, because inside a container the workspace is owned by
   a different UID than the user git runs as.
2. **Install `uv` if it is missing.** If `uv` is not on `PATH`, installs it
   with `pip install --break-system-packages uv`.
3. **Install vergil-tooling.**
    - If `pyproject.toml` declares `name = "vergil-tooling"`, the repository is
      vergil-tooling itself. The step runs `uv sync --frozen --group dev` and
      adds `.venv/bin` to `PATH`, so CI tests the PR's own code rather than a
      released version.
    - Otherwise it reads `[dependencies].vergil` from `vergil.toml` (e.g.
      `v2.1`) and runs `uv tool install` for vergil-tooling at that git tag.
      The step fails if `vergil.toml` or the `vergil` version is missing.
4. **Derive the CI versions.** Runs `derive.sh`, which reads `vergil.toml` and
   writes the three outputs. It fails the job with an `::error::` annotation
   when:
    - `vergil.toml` has no `[ci]` section;
    - `[ci].versions` is not a non-empty list of strings;
    - `[ci].primary-version` is set but is not a non-empty string.

The derivation lives in `derive.sh` rather than inline YAML so it can be unit
tested; see `actions/shared/setup/vergil/tests/derive.test.sh`. The
`smoke-setup-vergil` workflow runs those tests and checks the action's outputs
end to end.

## Configuration

The action reads two parts of the consuming repository's `vergil.toml`:

```toml
[dependencies]
vergil = "v2.1"            # vergil-tooling tag to install

[ci]
versions = ["3.12", "3.13", "3.14"]
# primary-version = "3.13" # optional; defaults to the highest entry
```

Set `[ci].primary-version` only when the primary version must not be the
highest entry.

## Related

- [`ci-test` reusable workflow](../workflows/ci-test.md) — uses the `versions`
  output to build its matrix.
- [`shared/setup/system-packages`](shared-setup-system-packages.md) and
  [`shared/setup/build-command`](shared-setup-build-command.md) — test-job
  steps that run after this one and need `vergil-tooling` on `PATH`.
- [`package/setup`](package-setup.md) — installs `vergil-tooling` and the
  package toolchain in package build and install-test containers instead.
