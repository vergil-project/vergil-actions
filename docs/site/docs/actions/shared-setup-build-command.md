# shared/setup/build-command

Runs the command a repository declares under `[container].build-command` in its
`vergil.toml`, so that CI test jobs perform the same build step as the local dev
container before the tests run.

This action is **wired automatically** into the [`ci-test`](../workflows/ci-test.md)
reusable workflow — consuming repositories do not add it themselves. It is
documented here for operators who need to understand what the step does and why
a test job might fail inside it.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/shared/setup/build-command@v2.1
```

The action takes no inputs. It requires `vergil-tooling` to be on `PATH`
(installed by the preceding `shared/setup/vergil` step in the `ci-test`
workflow), because it reads the command through `vrg-container-build-command`.

## Inputs

None.

## Behavior

The action runs a single step, `install.sh`, which:

1. Reads the command from `vrg-container-build-command --script`. This is the
   **single speller** shared with the local dev-container cache build, so CI and
   the dev container run the exact same build command — there is no second place
   the command is spelled out.
2. If the repository declares no `[container].build-command`, the script prints
   `No [container].build-command declared; skipping.` and exits `0`. The step is
   a no-op for repositories that need no build step.
3. Otherwise it runs the command via `bash -c`.

### Fail-closed, no retry

Unlike the sibling [`shared/setup/system-packages`](shared-setup-system-packages.md)
action — whose bounded retry absorbs a transient apt mirror flake — this action
**does not retry**. An arbitrary build command that fails is a real failure, not
a transient one, so retrying it would mask a genuine break. The step is
**fail-closed**: if the command exits non-zero, the step exits non-zero and the
test job fails. Nothing is silently skipped.

The logic lives in `install.sh` (not inline YAML) so it is unit-testable; see
`actions/shared/setup/build-command/tests/install.test.sh`.

### Test-runtime scope only

This action runs a **test-runtime** build step. It is wired only onto jobs that
execute the repository's tests — never onto lint or typecheck jobs, which do not
exercise the code and so do not need the build output. It runs after
`Install vergil-tooling` and after the system-packages install, before the
tests. See the [`ci-test` workflow reference](../workflows/ci-test.md) for where
it sits in the job graph.

## Configuration

The command is declared by the consuming repository in its `vergil.toml` under
`[container].build-command`. That key — its schema, semantics, and the
dev-container side of its effect — is documented on the vergil-tooling side:

- [`container-config` reference (`build-command`)](https://vergil-project.github.io/vergil-tooling/reference/container-config/)

This page covers only the vergil-actions CI side: which jobs run the build step
and how the step behaves.

## Related

- [`ci-test` reusable workflow](../workflows/ci-test.md) — runs the declared
  build-command on test jobs only.
- [`shared/setup/system-packages`](shared-setup-system-packages.md) — the
  sibling install step (bounded retry) that runs immediately before this one.
- [Repository Configuration](../configuration.md) — repository-level GitHub
  configuration overview.
