# Validation

## Canonical command

```bash
vrg-container-run -- vrg-validate
```

This runs all validation inside a per-branch cached container image that
`vrg-container-run` builds on first use from
`ghcr.io/vergil-project/dev-base:latest`: vergil-tooling is installed into
it at the version pinned in `vergil.toml` (`[dependencies] vergil`), and
the cache is rebuilt automatically when `vergil.toml` or the lockfiles
change. No manual host installs are needed beyond the vergil-tooling host
tool.

## Architecture

`vrg-validate` reads `primary_language` from `vergil.toml` and runs
common checks followed by language-specific checks from the built-in command
registry. Common checks include repo-profile validation, markdownlint,
shellcheck, yamllint, and actionlint.

## Custom checks

After the common checks, `vrg-validate` runs the repository's own
validator, `scripts/bin/validate-custom` (in CI, the `quality / custom`
job). It checks that every `*.test.sh` tracked in git has mode `100755`
(executable) and names each one that does not. It checks the mode git
records, not the one on disk, so fix an offender with `chmod +x <path>`
and then `git add <path>`. An in-place edit (`sed -i`, `perl -i`) can
replace a file and drop its executable bit, so check the mode after one
with `git ls-files -s <path>`.

The check's own tests are in `scripts/tests/`, which `validate-custom`
runs after the check.

## Tooling

The static validation tools are baked into the dev-base container image:

| Tool | Purpose |
| --- | --- |
| `actionlint` | GitHub Actions workflow linter |
| `shellcheck` | Shell script static analysis |
| `markdownlint` | Markdown formatting linter |
| `yamllint` | YAML formatting linter |

`vrg-validate` itself is not baked in — it arrives via the dynamic
vergil-tooling install described above. No host-level installs of any of
these tools are required.
