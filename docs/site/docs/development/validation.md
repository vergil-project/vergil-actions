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
