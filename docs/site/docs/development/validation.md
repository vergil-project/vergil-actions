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
job). It runs the two checks below, then the checks' own tests in
`scripts/tests/`.

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
