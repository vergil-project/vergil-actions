# ci-test

Unit and integration test workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | no | `[ci].versions` from `vergil.toml` | JSON array of language versions (e.g., `'["3.12", "3.13"]'`). **Deprecated** — omit it; the matrix is derived from `[ci].versions` in the consumer's `vergil.toml`. Still accepted for back-compat (a supplied value is honored verbatim), slated for removal in [#876](https://github.com/vergil-project/vergil-actions/issues/876) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |

## Version matrix

The matrix is derived from `[ci].versions` in the consumer's `vergil.toml` at
run time — the workflow's `matrix` job runs the shared setup action for its
`versions` output whenever the caller omits the `versions:` input. Callers are
thin: they pass only `language:` and `container-suffix:`.

## Jobs and check names

| Job | Check name | Condition |
| ----- | ------------ | ----------- |
| `unit / <version>` | `<caller> / unit / <version>` | Matrix-expanded per version — informational, not a required check |
| `evidence` | `test / evidence` | Aggregate gate — `needs` every `unit` leg, runs `if: always()`, and asserts each leg succeeded; a failed/skipped leg makes it **fail red** rather than skip. **This stable, version-agnostic gate is the required check** (see [Required Checks](../ci-gates/required-checks.md)) |

## Usage

```yaml
jobs:
  test:
    uses: vergil-project/vergil-actions/.github/workflows/ci-test.yml@v2.1
    with:
      language: python
      container-suffix: python
```

## System packages

Each `unit` job installs the system packages the repository declares under
`[container].system-packages` in its `vergil.toml`, via the
[`shared/setup/system-packages`](../actions/shared-setup-system-packages.md)
action. This runs on **test jobs only** — lint and typecheck jobs do not
exercise the code and are deliberately excluded, so the packages are installed
exactly where the tests need them and nowhere else.

The install is a no-op when a repository declares no system packages. When it
does declare them, the step installs with a bounded retry (to absorb transient
apt mirror flakes) and **fails closed** if a declared package has no install
candidate — the offending package and platform are named in the log and the
test job fails rather than running against a missing dependency. See the
[action reference](../actions/shared-setup-system-packages.md) for the full
behavior, and the
[`container-config` reference](https://vergil-project.github.io/vergil-tooling/reference/container-config/)
on the vergil-tooling side for the `[container].system-packages` key itself.

## Build command

After the system-packages install, each `unit` job runs the command the
repository declares under `[container].build-command` in its `vergil.toml`, via
the [`shared/setup/build-command`](../actions/shared-setup-build-command.md)
action. Like the system-packages install, this runs on **test jobs only** — lint
and typecheck jobs do not exercise the code and are deliberately excluded — and
it runs after the packages are installed, before the tests.

The step is a no-op when a repository declares no build command. When it does
declare one, the step **fails closed with no retry**: an arbitrary build command
that fails is a real failure, not a transient one, so — in deliberate contrast
to the system-packages install's bounded retry — a non-zero exit fails the test
job immediately rather than being retried and masking a genuine break.

After the command runs, the action exports `NODE_PATH` (the npm global root,
from `npm root -g`) so subsequent test steps can resolve a node library the
build baked out-of-workspace (e.g. `npm install -g <lib>`).

> **`require`-only caveat.** `NODE_PATH` is honoured by CommonJS `require`
> resolution only; ESM `import` ignores it. A baked library consumed via
> `import` will not resolve through `NODE_PATH` — a documented Node limitation,
> not an action bug.

See the [action reference](../actions/shared-setup-build-command.md) for the
full behavior, and the
[`container-config` reference](https://vergil-project.github.io/vergil-tooling/reference/container-config/)
on the vergil-tooling side for the `[container].build-command` key itself.

## Extension points

The `unit` job provides a version matrix scaffold. Consuming repositories
customize it by forking the workflow or by running language-specific test
commands in a separate workflow.
