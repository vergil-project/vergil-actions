# Required Checks

## Check matrix

The following table shows which CI checks apply to each repository category.
Checks marked **Required** must be configured as required status checks in the
[CI gates ruleset](repository-rulesets.md#ci-gates-ruleset).

| Check | Go Library | Python Library | Ruby Library | Java Library | Rust Library | Infrastructure | Documentation |
| ------- | ----------- | --------------- | ------------- | ------------- | ------------- | ---------------- | --------------- |
| `ci: standards-compliance` | Required | Required | Required | Required | Required | Required | Required |
| `ci: dependency-audit` | Required | Required | Required | Required | Required | — | — |
| `ci: actionlint` | — | — | — | — | — | Required | — |
| `ci: shellcheck` | — | — | — | — | — | Required | — |
| `ci: type-check` | — | Required | Required | — | — | — | — |
| `test: unit` | Required | Required | Required | Required | Required | — | — |
| `test: integration` | Required | Required | Required | Required | Required | — | — |
| `security: codeql` | Required | Required | Required | Required | Required | — | — |
| `security: semgrep` | Required | Required | Required | Required | Required | — | — |
| `security: trivy` | Required | Required | Required | Required | Required | — | — |
| `release: gates` | Required | Required | Required | Required | Required | — | — |

### Evidence gates are the required checks

The matrixed reusable workflows (`ci-audit`, `ci-quality`, `ci-test`) derive
their version matrix from `[ci].versions` in the consumer's `vergil.toml` at run
time (see [Reusable Workflows](../workflows/index.md)). Because the number and
names of the per-version legs change with `[ci].versions`, the **per-version
legs are not the required checks.** Requiring them would force a ruleset edit
every time a version was added or dropped.

Instead, each matrixed workflow emits one stable, version-agnostic **aggregate
gate** named `<kind> / evidence`:

| Workflow | Required aggregate gate |
| ---------- | ------------------------- |
| `ci-audit.yml` | `audit / evidence` |
| `ci-quality.yml` | `quality / evidence` |
| `ci-test.yml` | `test / evidence` |

The evidence job `needs` every matrix leg for its kind and runs with
`if: always()`, then asserts each leg's result is `success` before emitting.
A failed or skipped leg therefore makes the aggregate gate **fail red** rather
than skip green — closing the "green by absence" hole where a skipped leg would
otherwise leave the gate unset and non-blocking. Branch protection requires
these three stable gates; the per-version legs run and appear in the checks UI
but are informational, so the required-check set does not churn when
`[ci].versions` changes.

## Job name prefix convention

All CI job names use a category prefix followed by a colon and the job name.
This convention enables clear identification in the GitHub checks UI and
supports pattern-based branch protection rules.

```yaml
jobs:
  standards:
    name: "ci: standards-compliance"
  unit-tests:
    name: "test: unit"
  codeql:
    name: "security: codeql"
  release-gates:
    name: "release: gates"
```

## Reusable workflow check-name mapping

Each reusable workflow produces canonical check names. See
[Reusable Workflows](../workflows/index.md) for full details. For the matrixed
workflows the **required** check is the version-agnostic `<kind> / evidence`
aggregate; the per-version legs are informational (see [Evidence gates are the
required checks](#evidence-gates-are-the-required-checks) above).

| Workflow | Check names produced | Required check |
| ---------- | ---------------------- | ---------------- |
| `ci-docs.yml` | `CI Docs / docs` | `CI Docs / docs` |
| `ci-security.yml` | `CI Security / standards`, `CI Security / codeql`, `CI Security / trivy`, `CI Security / semgrep` | each job above |
| `ci-quality.yml` | `common`, `lint / <version>`, `typecheck / <version>` legs + `quality / evidence` aggregate | `quality / evidence` |
| `ci-audit.yml` | `dependencies / <version>` legs + `audit / evidence` aggregate | `audit / evidence` |
| `ci-test.yml` | `unit / <version>` legs + `test / evidence` aggregate | `test / evidence` |
| `ci-version-bump.yml` | `CI Version Bump / version-bump` | `CI Version Bump / version-bump` |

## Reusable workflow flags

The `ci-security.yml` reusable workflow accepts independent flags that
control which inner jobs run:

| Flag | Controls | Default |
| ---- | -------- | ------- |
| `run-standards` | `CI Security / standards` job | `true` |
| `run-security` | `CI Security / codeql`, `CI Security / trivy`, `CI Security / semgrep` jobs | `true` |
| `run-codeql` | `CI Security / codeql` job (requires `run-security` to also be true) | `true` |

Consuming repos must pass both flags explicitly so that push CI (tier 2) can
skip standards and security while PR CI (tier 3) runs the full suite:

```yaml
security-and-standards:
  uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
  with:
    language: <lang>
    run-standards: ${{ inputs.run-release-gates || 'true' }}
    run-security: ${{ inputs.run-security || 'true' }}
  permissions:
    contents: read
    security-events: write
    actions: read
```

Using a job-level `if` on a single flag (e.g., `if: inputs.run-security !=
'false'`) is **incorrect** because it conflates standards-compliance with
security scanning. The two-flag pattern allows each concern to be toggled
independently.

## Ruleset configuration

All required status checks are enforced via GitHub repository rulesets, not
legacy branch protection rules. Both `main` and `develop` are covered by the
same CI gates ruleset. See [Repository Rulesets](repository-rulesets.md) for
full configuration details including branch protection, CI gates, and tag
protection.
