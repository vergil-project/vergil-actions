# Validation

## Canonical command

```bash
vrg-container-run -- vrg-validate
```

This runs all validation inside a per-branch cached container image that
`vrg-container-run` builds on first use from
`ghcr.io/vergil-project/prod-base:latest`: vergil-tooling is installed into
it at the version pinned in `vergil.toml` (`[dependencies] vergil`), and
the cache is rebuilt automatically when `vergil.toml` or the lockfiles
change. No manual host installs are needed beyond the vergil-tooling host
tool.

## Documentation build

Build and preview the docs site with `vrg-container-docs`, which runs
mkdocs in the same prod-base image:

```bash
vrg-container-docs build --strict     # Strict docs build
vrg-container-docs serve              # Preview docs locally on port 8000
```

`vrg-container-run` publishes no port, so a `mkdocs serve` run through it
is not reachable from a host browser.

## Architecture

`vrg-validate` reads `primary_language` from `vergil.toml` and runs
common checks followed by language-specific checks from the built-in command
registry. Common checks include repo-profile validation, markdownlint,
shellcheck, yamllint, and actionlint.

## Custom checks

After the common checks, `vrg-validate` runs the repository's own
validator, `scripts/bin/validate-custom` (in CI, the `quality / custom`
job). It runs the checks below, then the action test suites, then the
checks' own tests in `scripts/tests/`.

### Test script modes

The first check fails naming each `*.test.sh` tracked in git whose mode is
not `100755` (executable). It checks the mode git records, not the one on
disk, so fix an offender with `chmod +x <path>` and then `git add <path>`.
An in-place edit (`sed -i`, `perl -i`) can replace a file and drop its
executable bit, so check the mode after one with `git ls-files -s <path>`.

### Test suite wiring

The second check, `scripts/bin/check-test-suites-run`, fails naming each
`*.test.sh` tracked in git that nothing runs. A suite counts as run when a
workflow under `.github/workflows/` runs it by its repo-relative path
(`bash <path>`, `sh <path>` or `./<path>`) on a line that is not a comment,
or when it sits directly in `scripts/tests/`, whose suites `validate-custom`
runs. A path named only in a comment or outside a workflow does not count.
The check reads the workflow text, so a step whose job never runs still
counts.

### Early-exit pipes

The third check, `scripts/bin/check-early-exit-pipes`, fails naming each
line, in the `*.sh`, `*.bash`, `*.yml` and `*.yaml` files and
`scripts/bin/*` tracked in git, where a pipeline feeds a consumer that
exits before reading all its input: `grep -q`, `grep -m`, `grep --quiet`,
`--silent`, `--max-count` or `head`. Under `set -o pipefail`, which every
suite here and GitHub's default `bash` shell set, such a consumer exits
on its first match, the producer dies of SIGPIPE writing its next line,
and the pipeline fails although it matched. Test the output with no pipe
instead: `grep -q <pattern> <<<"$(<producer>)"`.

### Secret environments

The fourth check, `scripts/bin/check-secret-environments`, fails naming
each workflow job that reads a secret able to write or act without
declaring the environment that holds it. The automation App's keys and the
registry publishing tokens live in each repository's `automation`
environment, whose deployment-branch policy admits only `develop` and
`main`, so a run from any other branch sees them unset. The package-signing
keys live in their own single-branch environments.

It reads every tracked workflow and, for each job that runs steps, collects
each `secrets.<NAME>` read inside a `${{ }}` expression, in any case and
skipping quoted strings. A job that calls a reusable workflow with `uses:`
runs no steps, so the called workflow's jobs are the ones checked. Each
secret is checked against the tables at the top of the script:

| Table | Secrets | Required environment |
| --- | --- | --- |
| `AUTOMATION_SECRETS` | `APP_CLIENT_ID`, `APP_PRIVATE_KEY`, `CARGO_REGISTRY_TOKEN` | `automation` |
| `SIGNING_SECRETS` | `PACKAGE_SIGNING_KEY`, `PACKAGE_SIGNING_PASSPHRASE` | `package-signing` or `index-signing` |
| `UNSCOPED_SECRETS` | `GITHUB_TOKEN`, `CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER` | none, each with its reason |

Nothing passes unclassified. The check also fails on:

- a secret that no table lists;
- a dynamic read of the secrets context (`secrets[...]`, `toJSON(secrets)`);
- a secret read in the workflow-level `env`, which every job sees;
- a workflow that does not parse.

To fix a failure, declare the job's environment (`environment: automation`,
or the signing environment). An environment named by an expression, such as
`${{ inputs.environment }}`, never counts as either, so a job that reads an
automation or signing secret must name its environment literally. A job
that reads no such secret may use one. A new secret goes into the table for the
environment that holds it. An unscoped entry needs a reason that says why
any job may read it.

The check also fails a reusable workflow that declares a secret
`required: true` under `on.workflow_call.secrets` while one of its jobs
names no environment literally: no `environment:`, one without a `name`,
one named by an expression, or a job that calls another reusable workflow,
which cannot declare one. GitHub checks a called workflow's required
secrets for each of its jobs, and a secret that exists only in an
environment is not provided to a job that declares none, even through
`secrets: inherit`, so GitHub refuses the whole call before any job starts
(vergil-project/vergil-actions#1428). To fix it, declare the secret
`required: false` and, in each job that reads it, fail loudly before using
it when it is empty, naming the secret, as `cd-release.yml`'s
`Require the automation App secrets` step does. Never fall back to
`GITHUB_TOKEN`.

### Nightly harness wiring

The fifth check, `scripts/bin/check-nightly-harnesses`, fails unless
`.github/workflows/nightly-harnesses.yml` calls every smoke workflow. Each
tracked `smoke-<name>.yml` must declare a `workflow_call` trigger, and the
nightly workflow must have a job `<name>` whose `uses:` is
`./.github/workflows/smoke-<name>.yml`. A job there that calls anything else
fails too, and so does a nightly workflow without its `schedule` and
`workflow_dispatch` triggers. See [Nightly harness run](#nightly-harness-run).

### Action test suites

`validate-custom` then runs every `*.test.sh` tracked in git directly in an
`actions/**/tests/` directory, from the repo root as CI does, and fails
naming each suite that fails. A suite listed in `CI_ONLY_ACTION_SUITES`, at
the top of `scripts/bin/validate-custom`, is skipped and named with its
reason. It stays CI-only because it reaches a live service or needs a tool
the validation image lacks. Each entry must name a tracked suite, so a
renamed or removed suite fails the run until its entry is updated. A new
suite runs in validation by default. The workflow that runs it in CI is
still needed for the wiring check above.

## Nightly harness run

On a pull request, each `smoke-*.yml` workflow runs only when its own paths
change. Its harnesses, though, run against the released vergil-tooling that
`vergil.toml`'s `[dependencies] vergil` pin installs: the newest `v2.1.Z`
tag. So a vergil-tooling release can break a harness with no change here,
and nothing would show it until an unrelated pull request ran that
workflow.

`.github/workflows/nightly-harnesses.yml` closes that gap. Once a day, and
on a manual `workflow_dispatch`, it calls every smoke workflow on develop.
Its `report` job then records the run in the org's operations queue under
the stable name `harness-nightly`, through the `ops/report` action:

- a failed or cancelled run opens the
  `ops: vergil-actions / harness-nightly failing` issue, or comments on it
  when it is already open;
- the first green run after a failure adds a recovery comment;
- nothing closes the issue: whoever works the queue closes it.

The issue links the run. The run's log shows the vergil-tooling version
installed and the harness case that failed.

A new smoke workflow needs a `workflow_call` trigger and its own job in
`nightly-harnesses.yml`, with that job added to the `report` job's `needs`
and `results`. The [nightly harness wiring](#nightly-harness-wiring) check
and `actions/ops/report/tests/reporting-jobs.test.sh` each fail until it
has them.

## Tooling

The static validation tools are baked into the prod-base container image:

| Tool | Purpose |
| --- | --- |
| `actionlint` | GitHub Actions workflow linter |
| `shellcheck` | Shell script static analysis |
| `markdownlint` | Markdown formatting linter |
| `yamllint` | YAML formatting linter |

`vrg-validate` itself is not baked in — it arrives via the dynamic
vergil-tooling install described above. No host-level installs of any of
these tools are required.
