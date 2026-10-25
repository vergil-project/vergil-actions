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
| `APP_CLIENT_ID` | Every repository with an `ops.yml` or `epic-rollup.yml`, and `[package]` repositories | Client ID of the org's automation GitHub App (`<org>-automation`) |
| `APP_PRIVATE_KEY` | Every repository with an `ops.yml` or `epic-rollup.yml`, and `[package]` repositories | Private key of the org's automation GitHub App |

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

These secrets hold the Client ID and private key of the org's **automation
GitHub App**. Workflows pass them to `actions/create-github-app-token` to mint
a short-lived installation token for work that `GITHUB_TOKEN` cannot do.

Each org has its own automation App, named `<org>-automation`. The App is
**owned by the org** (registered under the org's Developer settings, not a
personal account), and its installation covers **all repositories** in that
org:

| Org | App |
| --- | --- |
| `vergil-project` | `vergil-project-automation` |
| `logical-minds-foundry` | `logical-minds-foundry-automation` |
| `mnemosys-project` | `mnemosys-project-automation` |

The App is an automation identity, not a per-contributor one. It is separate
from the per-developer agent Apps described in vergil-tooling's
[Identity Architecture](https://vergil-project.github.io/vergil-tooling/latest/guides/identity-architecture/).

**Why a GitHub App?** A reusable workflow's `GITHUB_TOKEN` can carry only the
permissions its caller grants, and the standard `ops.yml` grants just
`contents: read` and `issues: write`. It is also limited to the repository the
run belongs to. The
App token supplies the extra scopes (for example Dependabot alerts or branch
deletion) and the cross-repository reach (the org's `.github` epics, the
org's `packages` index) these workflows need.

**Who uses it.** Every repository with an `ops.yml` needs these secrets, not
only library repositories:

| Workflow | Job or step | Token scope |
| -------- | ----------- | ----------- |
| [`ops-github-config.yml`](workflows/ops-github-config.md) | `branch-sweep`, `github-config`, `dependabot-audit` | Calling repository only |
| [`ops-epic-rollup.yml`](workflows/ops-epic-rollup.md) | `epic-rollup` (from the caller's `epic-rollup.yml`) | Calling repository and the epic repository |
| [`ops-epic-sweep.yml`](workflows/ops-epic-sweep.md) | `epic-sweep` | Every repository the App is installed on in the org |
| [`ops-upstream-refresh.yml`](workflows/ops-upstream-refresh.md) | `upstream-refresh` | Calling repository only |
| [`cd-release.yml`](workflows/cd-release-packages.md) | Package-index dispatch | `<org>/packages` only |

**App permissions required.** The table lists what each consumer needs, which
is the minimum the App must hold. Read the App's actual permission set from
its settings page before relying on it:

| Permission | Access | Needed by |
| ---------- | ------ | --------- |
| Metadata | Read-only | Required by GitHub (always enabled) |
| Administration | Read-only | `github-config`: `vrg-github-repo-config audit` reads repository settings, branch protection, rulesets, Actions permissions and whether vulnerability alerts are enabled |
| Contents | Read & write | `branch-sweep` (deletes branch refs); `upstream-refresh` (pushes the `upstream-refresh` branch, and deletes it when it closes a stale refresh PR); `cd-release.yml` package-index dispatch to `<org>/packages`; `github-config` reads `vergil.toml` and the CI workflow |
| Pull requests | Read & write | `upstream-refresh` (opens, updates, comments on and closes the refresh PR); `branch-sweep` reads them (decides which branches are finished) |
| Issues | Read & write | `ops-epic-rollup.yml` and `ops-epic-sweep.yml` (close, relabel and link issues) |
| Dependabot alerts | Read-only | `dependabot-audit` (`vrg-dependabot-audit` lists open alerts) |

**Administration stays read-only.** The Apps run only the read-only
`vrg-github-repo-config audit`. `vrg-github-repo-config apply`, which changes
settings and rulesets, is a human action that runs as the maintainer's own
`gh` login, never as the App. Do not grant Administration: Read & write.

vergil-actions' own release workflow (`cd.yml`) also uses the
`vergil-project-automation` App token for its checkout, because the
release tag it pushes points at the freeze-internal-refs commit, which changes
workflow files. That needs **Workflows: Read & write** (see
[local/freeze-internal-refs](actions/local-freeze-internal-refs.md#permissions)).
That is specific to this repository; consumer workflows do not need it.

**Creation steps:**

1. Go to the org's **Settings > Developer settings > GitHub Apps**, so the
   App is owned by the org.
2. Click **New GitHub App**.
3. Name it `<org>-automation` and set the homepage URL.
4. Under **Permissions > Repository permissions**, grant the permissions listed
   above.
5. Disable webhooks (not needed).
6. Create the app and note the **Client ID** from the app's settings page.
7. Under **Private keys**, click **Generate a private key**. Save the downloaded
   `.pem` file.
8. Under **Install App**, install it on the org and choose **All
   repositories**.
9. Make `APP_CLIENT_ID` and `APP_PRIVATE_KEY` available to every repository
   that calls the workflows above. For example, as repository secrets:

```bash
gh secret set APP_CLIENT_ID --repo <org>/<repo> --body "<client-id>"
gh secret set APP_PRIVATE_KEY --repo <org>/<repo> --body "$(cat <path-to-private-key>.pem)"
```

**Changing a permission later:**

1. On the App's settings page, open **Permissions & events**, change the
   permission and save.
2. Accept the change on the installation: **Org settings > GitHub Apps >
   \<app\> > Configure**, then review and accept the pending permission
   request. GitHub does not apply a new App permission to an installation
   until it is accepted, and until then minted tokens do **not** carry it.
   For Dependabot alerts, the `dependabot-audit` job exits 2 ("could not
   check") on every repository and the ops run fails.

**Key rotation:** Generate a new private key from the app's settings page, update
the `APP_PRIVATE_KEY` secret wherever it is stored for that org, then revoke the
old key. Each org has its own App and key, so rotate per org.

## Binary package environments

Repositories whose `vergil.toml` has a `[package]` section, and the
organization's `<org>/packages` index repository, keep their signing key in
GitHub **environments** (**Settings > Environments**), not in repository
secrets. Each environment's deployment-branch policy restricts it to a single
branch.

| Environment | Repository | Admits | Secrets | Used by |
| ----------- | ---------- | ------ | ------- | ------- |
| `package-signing` | Each `[package]` repository | `main` only | `PACKAGE_SIGNING_KEY`, `PACKAGE_SIGNING_PASSPHRASE` | The `package-sign` job in [`cd-release.yml`](workflows/cd-release-packages.md) |
| `index-signing` | `<org>/packages` | `develop` only | `PACKAGE_SIGNING_KEY`, `PACKAGE_SIGNING_PASSPHRASE` | The `build-index` job in [`publish-index.yml`](workflows/publish-index.md) |

`PACKAGE_SIGNING_KEY` holds the ASCII-armored export of the org signing
subkey. `index-signing` admits `develop` because `repository_dispatch` and
`schedule` runs always use the default branch.

Environment secrets reach these cross-repo reusable workflows **only** when
the caller passes `secrets: inherit`. An explicit `secrets:` map leaves them
empty (vergil-project/packages#6). See
[Release publishing secrets](getting-started.md#release-publishing-secrets).

The GitHub App behind `APP_CLIENT_ID` / `APP_PRIVATE_KEY` must also be
installed on `<org>/packages` with **Contents: Read & write**, so that
`cd-release.yml` can dispatch `package-released` to it after a packaged
release.

## Container system packages

A repository can declare extra Debian packages under `[container].system-packages`
in its `vergil.toml`. On CI, the [`ci-test`](workflows/ci-test.md) workflow
installs those packages on its **test jobs** (via the
[`shared/setup/system-packages`](actions/shared-setup-system-packages.md)
action), so tests run against the same system dependencies as the local dev
container. The key's schema and semantics are documented on the vergil-tooling
side: [`container-config` reference](https://vergil-project.github.io/vergil-tooling/latest/reference/container-config/).

## Container build command

A repository can declare a build step under `[container].build-command` in its
`vergil.toml`. On CI, the [`ci-test`](workflows/ci-test.md) workflow runs that
command on its **test jobs** (via the
[`shared/setup/build-command`](actions/shared-setup-build-command.md) action,
after the system-packages install and before the tests), so tests run against
the same build output as the local dev container. The step **fails closed with
no retry** — a failing build command fails the test job immediately rather than
being retried. After it runs, the action exports `NODE_PATH` so a node library
the build baked out-of-workspace resolves; note that `NODE_PATH` is honoured by
CommonJS `require` only and ignored by ESM `import`. The key's schema and
semantics are documented on the vergil-tooling side:
[`container-config` reference](https://vergil-project.github.io/vergil-tooling/latest/reference/container-config/).

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
2. **Scopes and repositories beyond the caller's grant** — a reusable
   workflow's `GITHUB_TOKEN` carries only what the caller grants and reaches
   only its own repository. The org's automation App token
   (`APP_CLIENT_ID` + `APP_PRIVATE_KEY`) is required for the nightly ops jobs
   (config audit, branch sweep, Dependabot alert audit), the epic roll-up and
   sweep, and the package-index dispatch. See
   [APP_CLIENT_ID and APP_PRIVATE_KEY](#app_client_id-and-app_private_key).

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
- [ ] Make `APP_CLIENT_ID` and `APP_PRIVATE_KEY` for the org's automation App
  available to the repository (every repository with an `ops.yml`, not only
  libraries)

```bash
gh secret set PROJECT_TOKEN --repo vergil-project/<repo> --body "<token>"
gh secret set APP_CLIENT_ID --repo vergil-project/<repo> --body "<client-id>"
gh secret set APP_PRIVATE_KEY --repo vergil-project/<repo> --body "$(cat <key>.pem)"
```

### 4. GitHub App installation

- [ ] Confirm the org's `<org>-automation` App installation has **All
  repositories** access, so it already covers the new repository
  (**Org settings > GitHub Apps > \<app\> > Configure**). There is no
  per-repository install step.
- [ ] Verify by checking **Settings > GitHub Apps** on the repository
- [ ] After the first nightly ops run, confirm the `dependabot-audit` job did
  not exit 2 ("could not check")

### 4a. Binary packages (`[package]` repositories only)

See [Binary package environments](#binary-package-environments).

- [ ] Create a `package-signing` environment whose deployment-branch policy
  admits only `main`
- [ ] Add `PACKAGE_SIGNING_KEY` and `PACKAGE_SIGNING_PASSPHRASE` to it
- [ ] Call `cd-release.yml` with
  `secrets: inherit  # nosemgrep: yaml.github-actions.security.secrets-inherit.secrets-inherit`
- [ ] Call `ci-package.yml` under a job keyed `package` and add
  `package / evidence` to the **CI gates** ruleset

For the `<org>/packages` index repository itself:

- [ ] Create an `index-signing` environment that admits only `develop`,
  holding `PACKAGE_SIGNING_KEY` and `PACKAGE_SIGNING_PASSPHRASE`
- [ ] Set **Settings > Pages > Source** to **GitHub Actions**
- [ ] Call `publish-index.yml` with `secrets: inherit` (same `nosemgrep`
  comment)

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
