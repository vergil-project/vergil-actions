# ci-audit

Dependency audit workflow.

## Inputs

| Input | Type | Required | Default | Description |
| ------- | ------ | ---------- | --------- | ------------- |
| `language` | string | yes | — | Primary language of the repository |
| `versions` | string | yes | — | JSON array of language versions (e.g., `'["3.12", "3.13"]'`) |
| `container-suffix` | string | no | `<language>` | Container image name suffix (e.g. `python`, `base`) |

## Secrets

| Secret | Required | Description |
| -------- | ---------- | ------------- |
| `CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER` | no | ConanCenter provider token for `conan audit`. Only meaningful for cpp repos; other ecosystems ignore it. Pass it explicitly via the caller's `secrets:` block — never `secrets: inherit`. When unset, the cpp audit command skips the conan gate with a notice instead of failing auth. |

## Jobs and check names

| Job | Check name | Description |
| ----- | ------------ | ------------- |
| `dependencies / <version>` | `CI Audit / dependencies / <version>` | Dependency audit (matrix-expanded) |

## Usage

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: python
      versions: '["3.12", "3.13", "3.14"]'
```

For cpp repos, forward the ConanCenter provider token through the explicit-secret
chain so `conan audit` can authenticate:

```yaml
jobs:
  audit:
    uses: vergil-project/vergil-actions/.github/workflows/ci-audit.yml@v2.1
    with:
      language: cpp
      versions: '["clang-20", "gcc-14"]'
      container-tag: '20'
      container-suffix: cpp-clang
    secrets:
      CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER: ${{ secrets.CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER }}
```

## Extension points

The `dependencies` job provides a version matrix scaffold for running
language-specific dependency audit tools (e.g., `pip-audit`, `npm audit`,
`bundler-audit`).
