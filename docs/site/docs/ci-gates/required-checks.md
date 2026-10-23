# Required Checks

## Required check set

The required status checks live in the
[CI gates ruleset](repository-rulesets.md#ci-gates-ruleset). `vrg-github-repo-config`
in vergil-tooling derives them from each repository's `vergil.toml`, so the set
depends on the repository's configuration rather than a fixed category. Check
names assume the standard caller job keys (`quality`, `security`, `docs`,
`audit`, `test`, `package`, `version`), because GitHub names a reusable-workflow
check `<caller job> / <job>`.

| Required check | Produced by | Required when |
| ---------------- | ------------- | --------------- |
| `quality / common` | `ci-quality.yml` | Always |
| `security / trivy` | `ci-security.yml` | Always |
| `security / semgrep` | `ci-security.yml` | Always |
| `docs / docs` | `ci-docs.yml` | The repo publishes docs (`[publish].docs`) |
| `Trivy`, `Semgrep OSS` | GitHub code scanning (SARIF upload) | GHAS is available |
| `security / codeql`, `CodeQL` | `ci-security.yml`, GitHub code scanning | GHAS is available and the primary language is supported by CodeQL |
| `audit / evidence` | `ci-audit.yml` | The language has a dependency-audit check |
| `quality / evidence` | `ci-quality.yml` | The language has a lint or typecheck check |
| `test / evidence` | `ci-test.yml` | The language has a unit-test check |
| `package / evidence` | `ci-package.yml` | `vergil.toml` has a `[package]` section |
| `version / version-bump` | `ci-version-bump.yml` | The repo has a release model (not `none`) |

`Trivy`, `Semgrep OSS` and `CodeQL` are the SARIF analysis checks that GitHub
creates when scanner results are uploaded to code scanning; see
[Security Scanning](security-scanning.md). Without GHAS they never report, so
they are required only where GHAS is available.

### Evidence gates are the required checks

The matrixed reusable workflows (`ci-audit`, `ci-quality`, `ci-test`) take
their version matrix from `vrg-ci-resolve` at run time, which resolves the
consumer's `vergil.toml` against the published language version window (see
[Reusable Workflows](../workflows/index.md)). Because the number and names of
the per-version legs change whenever the resolved set changes (the window
gains or drops a version, or the `[ci].versions` pin changes), the
**per-version legs are not the required checks.** Requiring them would force a
ruleset edit every time a version was added or dropped.

Instead, each matrixed workflow emits one stable, version-agnostic **aggregate
gate** named `<kind> / evidence`:

| Workflow | Required aggregate gate |
| ---------- | ------------------------- |
| `ci-audit.yml` | `audit / evidence` |
| `ci-quality.yml` | `quality / evidence` |
| `ci-test.yml` | `test / evidence` |
| `ci-package.yml` | `package / evidence` (repos with `[package]` only) |

A repo whose `vergil.toml` has a `[package]` section calls `ci-package.yml`
under a caller job keyed `package`, and `package / evidence` is a **required**
check for it. Its build and install-test legs vary with the `[package]`
targets and the matrix tier, so, as with the version legs, only the aggregate
gate is required. Repos without `[package]` do not call `ci-package.yml` and
do not require the gate.

The evidence job `needs` every matrix leg for its kind and runs with
`if: always()`, then asserts each leg's result is `success` before emitting.
A failed or skipped leg therefore makes the aggregate gate **fail red** rather
than skip green — closing the "green by absence" hole where a skipped leg would
otherwise leave the gate unset and non-blocking. Branch protection requires
these stable gates (plus `package / evidence` for `[package]` repos); the
per-version legs run and appear in the checks UI but are informational, so the
required-check set does not churn when the resolved version set changes.

`ci-security.yml` also has an `evidence` job (`security / evidence`), but it is
not a required check: the scanner jobs are not matrixed, so they are required
directly.

## Reusable workflow check-name mapping

Each reusable workflow produces the check names below, shown with the standard
caller job key as the prefix. See [Reusable Workflows](../workflows/index.md)
for full details. For the matrixed workflows the **required** check is the
version-agnostic `<kind> / evidence` aggregate; the per-version legs are
informational (see [Evidence gates are the required
checks](#evidence-gates-are-the-required-checks) above).

| Workflow | Check names produced | Required check |
| ---------- | ---------------------- | ---------------- |
| `ci-docs.yml` | `docs / docs` | `docs / docs` (repos that publish docs) |
| `ci-security.yml` | `security / codeql`, `security / trivy`, `security / semgrep`, `security / evidence` | `security / trivy`, `security / semgrep`; `security / codeql` with GHAS and a CodeQL-supported language |
| `ci-quality.yml` | `quality / matrix`, `quality / setup`, `quality / common`, `quality / lint / <version>`, `quality / typecheck / <version>` legs + `quality / evidence` aggregate | `quality / common`, `quality / evidence` |
| `ci-audit.yml` | `audit / matrix`, `audit / dependencies / <version>` legs + `audit / evidence` aggregate | `audit / evidence` |
| `ci-test.yml` | `test / matrix`, `test / unit / <version>` legs + `test / evidence` aggregate | `test / evidence` |
| `ci-version-bump.yml` | `version / setup`, `version / version-bump` | `version / version-bump` (repos with a release model) |
| `ci-package.yml` (`[package]` repos only) | `package / matrix`, `package / build / <cell>`, `package / install-test / <cell>` legs + `package / evidence` aggregate | `package / evidence` |

## ci-security.yml flags

The `ci-security.yml` reusable workflow accepts these flags to control which
scanner jobs run (see [ci-security](../workflows/ci-security.md) for every
input):

| Flag | Controls | Default |
| ---- | -------- | ------- |
| `run-security` | `security / codeql`, `security / trivy`, `security / semgrep` jobs | `true` |
| `run-codeql` | `security / codeql` job (requires `run-security` to also be true) | `true` |
| `upload-sarif` | Upload of SARIF to code scanning; when false, `security / codeql` is skipped | `true` |

```yaml
security:
  uses: vergil-project/vergil-actions/.github/workflows/ci-security.yml@v2.1
  permissions:
    contents: read
    security-events: write
    actions: read
  with:
    language: <lang>
```

## Ruleset configuration

All required status checks are enforced via GitHub repository rulesets, not
legacy branch protection rules. Both `main` and `develop` are covered by the
same CI gates ruleset. See [Repository Rulesets](repository-rulesets.md) for
full configuration details including branch protection, CI gates, and tag
protection.
