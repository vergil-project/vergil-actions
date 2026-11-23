# ops/report

Reports a named unattended job's result to the org's operations queue (epic
[vergil-project/.github#1494](https://github.com/vergil-project/.github/issues/1494)).
It runs
[`vrg-ops-report`](https://github.com/vergil-project/vergil-tooling/blob/develop/docs/site/docs/reference/cli-tools-overview.md)
from vergil-tooling as the org's automation App. The reporter keeps one open
ops issue per job, titled `ops: <repo> / <job> failing` and labelled
`ops-report`, under the org's operations epic in `<org>/.github`:

- a failure or a cancel opens that issue, or comments on it when it is open;
- the first green run after one records the recovery on it;
- a green run with no open issue, or one already recovered, writes nothing;
- a run whose jobs were all skipped reports nothing at all.

Nothing closes an ops issue: a person closes it once the cause is dealt with.
The issue holds only the run link, the job name, the failing step, the
conclusion and the date, never log text.

A reporting job is the last job of its workflow, with `if: always()`, so it
runs whatever the jobs it reports did.

## Usage

```yaml
jobs:
  report:
    needs: [build-index, deploy]
    if: always()
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
        with:
          persist-credentials: false
      - uses: vergil-project/vergil-actions/actions/ops/report@v2.1
        env:
          VRG_TRUSTED_AUTHORS: ${{ vars.VRG_TRUSTED_AUTHORS }}
          VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
        with:
          job: publish-index
          results: ${{ needs.build-index.result }},${{ needs.deploy.result }}
          app-client-id: ${{ secrets.APP_CLIENT_ID }}
          app-private-key: ${{ secrets.APP_PRIVATE_KEY }}
```

The job checks out the repository first: setting up vergil-tooling reads its
`vergil.toml`. The `uses:` step sets `VRG_TRUSTED_AUTHORS` and
`VRG_AUTOMATION_APP` from the org Actions variables in its own `env`: a
composite action cannot read `vars`, and the step's `env` reaches every step
of the action (see [Variables](../configuration.md#variables)). Set them
nowhere else: on the job or the workflow, `VRG_AUTOMATION_APP` would reach
steps that hold no App token.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `job` | Yes | — | The job's stable name, the report key: for example `docs-refresh`. Never the workflow file, so renaming a file keeps the issue |
| `results` | Yes | — | Comma list of the `needs.<job>.result` values of every GitHub job that makes up the named job |
| `step` | No | `""` | The failing step's name, when known |
| `app-client-id` | Yes | — | The automation App's client ID (`secrets.APP_CLIENT_ID`) |
| `app-private-key` | Yes | — | The automation App's private key (`secrets.APP_PRIVATE_KEY`) |

The results combine into one: any `failure` makes a failure; else any
`cancelled` makes a cancel; else at least one `success` makes a success; all
`skipped` reports nothing.

## Behavior

1. **Require develop.** On any ref other than `refs/heads/develop` the action
   prints a notice and stops, with no token minted and nothing reported, so a
   feature-branch `workflow_dispatch` files nothing. On develop it fails when
   `VRG_AUTOMATION_APP` or `VRG_TRUSTED_AUTHORS` is empty or unset.
2. **Mint the App token**, with `permission-issues: write` only, for the
   calling repository and the org's `.github` repository (the operations
   epic lives there).
3. **Set up vergil-tooling** with that token as `GH_TOKEN`. The setup's
   identity check sees `VRG_AUTOMATION_APP` and verifies the token as that
   App's, so the token is minted before the setup.
4. **Report** with `vrg-ops-report --repo <owner/repo> --job <job> --results
   <results> --run-url <run attempt URL>`, adding `--step` when it is set. A
   reporter that cannot read or write fails the job.

Every step after the first runs only when the first one allowed it.
`tests/ops-report-ref-guard.test.sh` and `tests/ops-report-inputs.test.sh`
check this layout; `.github/workflows/smoke-ops-report.yml` runs them.

## Token

The token holds Issues write (and Metadata read, which GitHub always grants)
on two repositories: the calling one, for its ops issue and the `ops-report`
label, and `<org>/.github`, for the operations epic and the sub-issue link.
`GITHUB_TOKEN` cannot be used: the issues must be written by the automation
App, whose authorship is what the reporter trusts when it reads them back.
