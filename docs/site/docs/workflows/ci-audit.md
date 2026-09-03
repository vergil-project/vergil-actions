# ci-audit

Dependency audit workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | no | `[ci].versions` from `vergil.toml` | JSON array of language versions (e.g., `'["3.12", "3.13"]'`). **Deprecated** — omit it; the matrix is derived from `[ci].versions` in the consumer's `vergil.toml`. Still accepted for back-compat (a supplied value is honored verbatim), slated for removal in [#876](https://github.com/vergil-project/vergil-actions/issues/876) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |

## Secrets

| Secret | Required | Description |
| -------- | ---------- | ------------- |
| `CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER` | no | ConanCenter provider token for `conan audit`. Only meaningful for cpp repos; other ecosystems ignore it. Pass it explicitly via the caller's `secrets:` block — never `secrets: inherit`. When unset, the cpp audit command skips the conan gate with a notice instead of failing auth. |

## Version matrix

The matrix is derived from `[ci].versions` in the consumer's `vergil.toml` at
run time — the workflow's `matrix` job runs the shared setup action for its
`versions` output whenever the caller omits the `versions:` input. Callers are
thin: they pass only `language:` and `container-suffix:`.

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `dependencies / <version>` | `<caller> / dependencies / <version>` | Dependency audit (matrix-expanded — informational, not a required check) |
| `evidence` | `audit / evidence` | Aggregate gate — `needs` every `dependencies` leg, runs `if: always()`, and asserts each leg succeeded; a failed/skipped leg makes it **fail red** rather than skip. **This stable, version-agnostic gate is the required check** (see [Required Checks](../ci-gates/required-checks.md)) |

## Usage

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: python
      container-suffix: python
```

For cpp repos, forward the ConanCenter provider token through the explicit-secret
chain so `conan audit` can authenticate:

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: cpp
      container-suffix: cpp-clang
    secrets:
      CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER: ${{ secrets.CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER }}
```

## Extension points

The `dependencies` job provides a version matrix scaffold for running
language-specific dependency audit tools (e.g., `pip-audit`, `npm audit`,
`bundler-audit`).
