# Environment and Tooling

## Git hooks

Configure the repository to use the shared git hooks:

```bash
git config core.hooksPath .githooks
```

This enables the pre-commit hook that prevents direct commits to protected
branches (`main`, `develop`).

## Host prerequisites

Install the vergil-tooling host tool, which provides `vrg-container-run`,
`vrg-commit`, `vrg-validate`, and other workflow commands:

```bash
uv tool install 'vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1'
```

Docker must be running for `vrg-container-run` to work.

## Validation and development tools

All validation tools (actionlint, shellcheck, markdownlint, yamllint) and
documentation tools (mkdocs-material, mike) are pre-installed in the
`ghcr.io/vergil-project/dev-base:latest` container image. vergil-tooling
itself is not — on first use, `vrg-container-run` builds a per-branch
cached image with vergil-tooling installed at the version pinned in
`vergil.toml`, and rebuilds it when `vergil.toml` or the lockfiles
change. No manual host installs are needed.

```bash
vrg-container-run -- vrg-validate             # Run all validation checks
vrg-container-run -- mkdocs serve -f docs/site/mkdocs.yml   # Preview docs locally
vrg-container-run -- mkdocs build -f docs/site/mkdocs.yml --strict  # Strict docs build
```
