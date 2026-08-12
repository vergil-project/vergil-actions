# shared/setup/system-packages

Installs the Debian packages a repository declares under
`[container].system-packages` in its `vergil.toml`, so that CI test jobs run
against the same system dependencies as the local dev container.

This action is **wired automatically** into the [`ci-test`](../workflows/ci-test.md)
reusable workflow — consuming repositories do not add it themselves. It is
documented here for operators who need to understand what the step does and why
a test job might fail inside it.

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/shared/setup/system-packages@v2.1
```

The action takes no inputs. It requires `vergil-tooling` to be on `PATH`
(installed by the preceding `shared/setup/vergil` step in the `ci-test`
workflow), because it reads the package list through
`vrg-container-system-packages`.

## Inputs

None.

## Behavior

The action runs a single step, `install.sh`, which:

1. Reads the apt install snippet from `vrg-container-system-packages
   --install-script`. This is the **single speller** shared with the local
   dev-container cache build, so CI and the dev container install the exact
   same packages the same way — there is no second place a package list is
   spelled out.
2. If the repository declares no `[container].system-packages`, the script
   prints `No [container].system-packages declared; skipping.` and exits `0`.
   The step is a no-op for repositories that need no extra system packages.
3. Otherwise it runs the install snippet with a **bounded retry** (3 attempts
   by default, with a delay between attempts) so a transient apt mirror flake
   does not fail the job.
4. **Fail-closed on a missing candidate.** If a declared package genuinely has
   no install candidate, the retries are exhausted and the step exits non-zero
   with the speller's own "not installable" message — naming the offending
   package and the platform — still visible in the log. Nothing is silently
   skipped: an unresolvable package fails the test job rather than letting the
   tests run against a missing dependency.

The retry and fail-closed logic lives in `install.sh` (not inline YAML) so it
is unit-testable; see `actions/shared/setup/system-packages/tests/install.test.sh`.

### Test-runtime scope only

This action installs **test-runtime** dependencies. It is wired only onto jobs
that execute the repository's tests — never onto lint or typecheck jobs, which
do not exercise the code and so do not need its system dependencies. See the
[`ci-test` workflow reference](../workflows/ci-test.md) for where it sits in the
job graph.

## Configuration

The package list is declared by the consuming repository in its `vergil.toml`
under `[container].system-packages`. That key — its schema, semantics, and the
dev-container side of its effect — is documented on the vergil-tooling side:

- [`container-config` reference (`system-packages`)](https://vergil-project.github.io/vergil-tooling/reference/container-config/)

This page covers only the vergil-actions CI side: which jobs run the install
step and how the step behaves.

## Related

- [`ci-test` reusable workflow](../workflows/ci-test.md) — installs declared
  system packages on test jobs only.
- [`shared/setup/build-command`](shared-setup-build-command.md) — the sibling
  build step (fail-closed, no retry) that runs immediately after this one.
- [Repository Configuration](../configuration.md) — repository-level GitHub
  configuration overview.
