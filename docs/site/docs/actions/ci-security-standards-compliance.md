# standards-compliance

PR-specific compliance checks: issue linkage and auto-close keyword rejection.
Repository profile, markdown, and other structural validations are handled by
`vrg-validate` (run separately in the CI workflow).

## Usage

```yaml
- uses: vergil-project/vergil-actions/actions/ci/security/standards-compliance@v2.1
```

## Inputs

None. The action has no configurable inputs.

## Permissions

- `contents: read` (default for `github.token`)

## Behavior

1. **Validate PR issue linkage** — On pull requests, runs `st-pr-issue-linkage`
   to verify the PR body references a GitHub issue.
2. **Reject auto-close linkage keywords** — On pull requests, inspects the PR
   body for `Fixes`, `Closes`, or `Resolves` keywords targeting an issue
   reference. These keywords are rejected because auto-closing bypasses the
   `st-finalize-repo` workflow. Use `Ref #N` instead.

Both steps only run on `pull_request` events.

## Examples

### Basic usage

```yaml
- uses: actions/checkout@v6
  with:
    fetch-depth: 0
- uses: vergil-project/vergil-actions/actions/ci/security/standards-compliance@v2.1
```

## GitHub configuration

- **Branch protection** — Recommended: require this check to pass on `develop`
  and `main` branches.
