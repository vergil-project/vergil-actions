# Repository Configuration

This page documents the GitHub configuration prerequisites that each managed
repository needs before CI workflows, automation, and project integration work
correctly. For action-specific configuration (inputs, outputs, behavior), see the
[Action Reference](actions/index.md).

## Secrets

Each repository requires specific secrets depending on its workflow set. Secrets
are configured in **Settings > Secrets and variables > Actions**.

| Secret | Required by | Purpose |
| ------ | ----------- | ------- |
| `PROJECT_TOKEN` | All repositories | Adds new issues to the GitHub Project via the `add-to-project` workflow |
| `APP_CLIENT_ID` | Library repositories | GitHub App Client ID for release workflows |
| `APP_PRIVATE_KEY` | Library repositories | GitHub App signing key for release workflows |

### PROJECT_TOKEN

A classic personal access token (PAT) that grants the `add-to-project` workflow
permission to add issues to a user-owned GitHub Project.

**Required scopes:** `project`, `repo`

**Why a classic PAT?** Fine-grained personal access tokens do not support
user-owned Projects v2. The GitHub Projects v2 GraphQL API requires a classic
token with the `project` scope.

**Creation steps:**

1. Go to **Settings > Developer settings > Personal access tokens > Tokens
   (classic)**.
2. Click **Generate new token (classic)**.
3. Set a descriptive name (e.g., `add-to-project automation`).
4. Select scopes: `project` (full control) and `repo` (full control).
5. Generate the token and copy it immediately.
6. Set the secret in each repository:

```bash
gh secret set PROJECT_TOKEN --repo vergil-project/<repo> --body "<token>"
```

!!! warning "Do not pipe tokens via stdin"
    Always use the `--body` flag when setting secrets with `gh secret set`.
    Piping the token via stdin (`printf '%s' 'TOKEN' | gh secret set ...`)
    can corrupt the secret value during encryption, causing "Bad credentials"
    errors at runtime that are difficult to diagnose.

### APP_CLIENT_ID and APP_PRIVATE_KEY

These secrets are used together to generate a GitHub App installation token at
publish time. The token is used by the CD release workflow to push workflow
file changes that `GITHUB_TOKEN` cannot.

**Why a GitHub App?** Pull requests created by the default `GITHUB_TOKEN` do not
trigger CI workflows. This is a GitHub security measure to prevent recursive
workflow runs. A GitHub App token acts as a separate identity, so PRs it creates
trigger CI normally and can auto-merge.

**App permissions required:**

| Permission | Access | Purpose |
| ---------- | ------ | ------- |
| Contents | Read & write | Create branches, push commits |
| Pull requests | Read & write | Create and merge PRs |
| Workflows | Read & write | Push commits that modify workflow files |
| Metadata | Read-only | Required by GitHub (always enabled) |

**Creation steps:**

1. Go to **Settings > Developer settings > GitHub Apps**.
2. Click **New GitHub App**.
3. Set the app name and homepage URL.
4. Under **Permissions > Repository permissions**, grant the permissions listed
   above.
5. Disable webhooks (not needed).
6. Create the app and note the **Client ID** from the app's settings page.
7. Under **Private keys**, click **Generate a private key**. Save the downloaded
   `.pem` file.
8. Under **Install App**, install it on your account and grant access to the
   repositories that use the publish workflow.
9. Set the secrets in each library repository:

```bash
gh secret set APP_CLIENT_ID --repo vergil-project/<repo> --body "<client-id>"
gh secret set APP_PRIVATE_KEY --repo vergil-project/<repo> --body "$(cat <path-to-private-key>.pem)"
```

**Key rotation:** Generate a new private key from the app's settings page, update
the `APP_PRIVATE_KEY` secret in all library repositories, then revoke the old
key.

## Container system packages

A repository can declare extra Debian packages under `[container].system-packages`
in its `vergil.toml`. On CI, the [`ci-test`](workflows/ci-test.md) workflow
installs those packages on its **test jobs** (via the
[`shared/setup/system-packages`](actions/shared-setup-system-packages.md)
action), so tests run against the same system dependencies as the local dev
container. The key's schema and semantics are documented on the vergil-tooling
side: [`container-config` reference](https://vergil-project.github.io/vergil-tooling/reference/container-config/).

## GitHub Project integration

The `add-to-project` workflow automatically adds new issues to a GitHub Project
when they are opened. Each repository has an `add-to-project.yml` workflow that
references a project URL and uses the `PROJECT_TOKEN` secret.

```yaml
- uses: actions/add-to-project@v1.0.2
  with:
    project-url: https://github.com/users/<owner>/projects/<number>
    github-token: ${{ secrets.PROJECT_TOKEN }}
```

The `project-url` value varies by repository — repositories may belong to
different projects. This is configured directly in the workflow file, not as a
secret.

## Repository rulesets

Every managed repository uses three rulesets to enforce merge requirements:

- **Branch protection** — PR requirements for `main` and `develop`
- **CI gates** — Required status checks for `main` and `develop`
- **Tag protection** — Protect semver release tags (`v*.*.*`); allow rolling minor tags

For detailed configuration including settings, check names per repository type,
and API commands, see [Repository Rulesets](ci-gates/repository-rulesets.md).

## Workflow permissions

GitHub Actions workflows use the `GITHUB_TOKEN` for most operations. This token
is automatically created per workflow run and scoped to the repository.

### Default GITHUB_TOKEN permissions

Each workflow declares its minimum required permissions at the top level:

```yaml
permissions:
  contents: read
```

| Permission | Typical workflows |
| ---------- | ----------------- |
| `contents: read` | CI (test, lint, validate) |
| `contents: write` | Documentation deployment, publish (tagging) |
| `security-events: write` | CodeQL, Semgrep, Trivy (SARIF upload) |
| `attestations: write` | Build provenance attestation (Python, Java) |
| `id-token: write` | OIDC-based publishing (PyPI trusted publisher) |
| `pull-requests: write` | Publish workflow (version bump PR creation) |

### When external tokens are needed

The `GITHUB_TOKEN` is insufficient in two cases:

1. **GitHub Project access** — The `GITHUB_TOKEN` cannot interact with
   user-owned Projects v2. The `PROJECT_TOKEN` (classic PAT) is required.
2. **CI-triggering PRs** — PRs created by `GITHUB_TOKEN` do not trigger
   workflow runs. The GitHub App token (`APP_CLIENT_ID` + `APP_PRIVATE_KEY`) is
   required for the version bump PR to trigger CI and auto-merge.

## Auto-merge

All managed repositories have **auto-merge enabled** in repository settings.
This allows PRs to merge automatically once all required status checks pass.

To enable: **Settings > General > Pull Requests > Allow auto-merge**.

## New repository onboarding checklist

Use this checklist when adding a new repository to the managed environment.

### 1. Repository settings

- [ ] Set default branch to `develop`
- [ ] Enable auto-merge (**Settings > General > Pull Requests**)
- [ ] Enable **Automatically delete head branches**

### 2. Rulesets

Create three rulesets per the standard configuration:

- [ ] **Branch protection** — targeting `main` and `develop`
  ([details](ci-gates/repository-rulesets.md#branch-protection-ruleset))
- [ ] **CI gates** — targeting `main` and `develop` with required checks
  ([details](ci-gates/repository-rulesets.md#ci-gates-ruleset))
- [ ] **Tag protection** — targeting `v*.*.*` with admin bypass
  ([details](ci-gates/repository-rulesets.md#tag-protection-ruleset))

!!! warning "Use explicit branch references"
    Always use `refs/heads/main` and `refs/heads/develop` in ruleset conditions.
    Never use `~DEFAULT_BRANCH` — it resolves to `develop` (the default branch),
    silently leaving `main` unprotected. See
    [Branch targeting](ci-gates/repository-rulesets.md#branch-targeting).

### 3. Secrets

- [ ] Set `PROJECT_TOKEN` (all repositories)
- [ ] Set `APP_CLIENT_ID` and `APP_PRIVATE_KEY` (library repositories only)

```bash
gh secret set PROJECT_TOKEN --repo vergil-project/<repo> --body "<token>"
gh secret set APP_CLIENT_ID --repo vergil-project/<repo> --body "<client-id>"
gh secret set APP_PRIVATE_KEY --repo vergil-project/<repo> --body "$(cat <key>.pem)"
```

### 4. GitHub App installation

- [ ] Install the GitHub App on the new repository (library repos only)
- [ ] Verify by checking **Settings > GitHub Apps** on the repository

### 5. Workflow files

- [ ] Add `add-to-project.yml` with the correct project URL
- [ ] Add `ci.yml` with standard checks for the repository type
- [ ] Add `cd.yml` with docs and/or release jobs as needed

### 6. CI gates activation

- [ ] Push the CI workflow and verify all checks run
- [ ] Add each check name to the **CI gates** ruleset
  ([procedure](ci-gates/repository-rulesets.md#adding-a-new-required-check))

### 7. Verification

- [ ] Open a test issue and confirm it appears in the GitHub Project
- [ ] Open a test PR and confirm all required checks run
- [ ] Confirm auto-merge works after checks pass
