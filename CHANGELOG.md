# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [2.1.2] - 2026-06-05

### Bug fixes

- gate follows release-model instead of run-release wiring

### Documentation

- describe dynamic cached-image tooling install
- replace vrg-docker-run, fix v1.4 pin and pre-installed claim

## [2.1.1] - 2026-06-04

### Bug fixes

- track @develop for standards-compliance setup ref (#679)

### Chores

- bump vergil pin to v2.1 (#679)

### Documentation

- add v2.0→v2.1 canary design (#679)
- revise v2.0→v2.1 canary design after pushback (#679)
- drop unneeded VERSION bump from canary design (#679)
- expand canary doc scope to full @v2.0 sweep (#679)
- add v2.0→v2.1 canary implementation plan (#679)
- note no-auto-close-keyword PR constraint (#679)
- bump consumer @v2.0 references to v2.1 (#679)

## [2.1.0] - 2026-06-04

### Bug fixes

- treat missing origin/main as a first-release no-op

## [2.0.28] - 2026-06-02

### CI

- add build-only docs verification to PR CI

## [2.0.27] - 2026-06-01

### Bug fixes

- run codeql on bare runner so autobuild has a language toolchain

## [2.0.26] - 2026-05-28

### Bug fixes

- separate language and container-suffix inputs in cd-release.yml

## [2.0.25] - 2026-05-28

### Bug fixes

- revert to Docker-based approach for bare-runner compatibility

## [2.0.24] - 2026-05-28

### Bug fixes

- install uv via setup-uv when not present on bare runners
- use astral-sh/setup-uv@v7 (v8 has no rolling major tag)
- use pip to install uv on bare runners instead of astral-sh/setup-uv

## [2.0.23] - 2026-05-28

### Bug fixes

- run codeql job in container image

## [2.0.22] - 2026-05-28

### Bug fixes

- resolve v2.0.21 breaking changes in release and trivy workflows

## [2.0.21] - 2026-05-27

### Bug fixes

- handle missing primary-language in vergil.toml
- revert internal refs to @develop and replace trivy shell with vrg-trivy-scan
- use local action paths for true self-referencing CI
- run trivy job in prod-base container
- revert trivy action to original inline Docker approach
- use dev container prefix for CI
- eliminate shell injection patterns in action YAML files
- replace Docker orchestration with vrg-trivy-scan direct invocation

### Chores

- remove invalid primary-language from vergil.toml
- remove deprecated version-bump-pr action

### Refactoring

- replace inline shell with vrg-semgrep-scan
- replace inline SARIF evaluation with vrg-sarif-evaluate
- replace inlined Python scripts with vrg-docs-stage and vrg-docs-patch-nav
- replace case-statement command derivation with vrg-ecosystem-resolve
- replace inline validation with vrg-release-validate-inputs
- replace inline sed/grep logic with vrg-freeze-refs
- remove redundant auto-close check already handled by vrg-pr-issue-linkage
- replace inline comparison with vrg-version-divergence
- replace sed TOML parsing with python3 tomllib

## [2.0.20] - 2026-05-27

### Bug fixes

- map go to p/golang and capture scan exit codes

## [2.0.19] - 2026-05-26

### CI

- migrate from git hook to Claude Code hook guard
- add SARIF warning-level enforcement

### Chores

- align shell command policy with upstream template

### Documentation

- address self-review findings in container-suffix spec
- apply pushback findings to container-suffix spec
- add container-suffix defaults implementation plan

## [2.0.18] - 2026-05-25

### Chores

- bump version to 2.0.18

## [2.0.17] - 2026-05-25

### Chores

- bump version to 2.0.17

### Documentation

- sync template with vrg-container-run rename

### Refactoring

- remove version-bump-pr and rolling-tag from release pipeline

## [2.0.16] - 2026-05-23

### Bug fixes

- add missing contents:read permission to security scanner jobs

### Chores

- bump version to 2.0.16

## [2.0.15] - 2026-05-23

### Bug fixes

- guard version-divergence fetch against credential race
- skip Semgrep language ruleset for unsupported languages

### Chores

- bump version to 2.0.15
- add missing container-tag and container-suffix parameters

### Features

- fail CI on CodeQL findings at warning level or above

## [2.0.14] - 2026-05-22

### Bug fixes

- use app token for github-config audit

### Chores

- bump version to 2.0.14

### Documentation

- add design spec for command-injection ruleset expansion

### Features

- add p/command-injection to base config

## [2.0.13] - 2026-05-21

### Bug fixes

- accept container-tag input in ci-audit and ci-test workflows
- sync pre-commit hook with canonical vergil-tooling template

### Chores

- bump version to 2.0.13

## [2.0.12] - 2026-05-21

### Bug fixes

- default container-suffix to 'base' in ci-audit and ci-test

### Chores

- bump version to 2.0.12

## [2.0.11] - 2026-05-21

### Chores

- bump version to 2.0.11

## [2.0.10] - 2026-05-21

### Chores

- bump to 2.0.10 for release retry

## [2.0.9] - 2026-05-21

### Bug fixes

- use correct vrg-github-repo-config command name in ops workflow
- align CLAUDE.md shell policy with canonical template

### Chores

- bump version to 2.0.9
- add label to version selector in site header

## [2.0.8] - 2026-05-20

### Bug fixes

- align CLAUDE.md with canonical consumer template
- add dev-base container to github-config job
- replace hardcoded container images with input-driven prefix
- revert cd.yml overrides and update container prefix docs
- correct container prefix docs for local validation
- replace vergil.toml prefix instructions with vrg-docker-run reference
- correct vrg-docker-run documentation URL

### Chores

- bump version to 2.0.8

## [2.0.7] - 2026-05-19

### Bug fixes

- pass --commit origin/main to vrg-resolve-tracking-issue

### Chores

- bump version to 2.0.6

## [2.0.6] - 2026-05-19

### Chores

- bump version to 2.0.5
- remove redundant vergil-tooling key from vergil.toml
- remove per-repo templates in favor of org defaults
- remove co-authors section, normalize vergil dep to v2.0

### Features

- deploy permission model configuration
- deploy deny rules to project-level settings
- replace title-scanning with deterministic tracking-issue lookup

## [2.0.4] - 2026-05-13

### Chores

- bump version to 2.0.4
- unpin create-github-app-token back to @v3
- rename client-id to app-id for create-github-app-token v3

## [2.0.3] - 2026-05-13

### Chores

- bump version to 2.0.3

### Documentation

- update site docs to post-migration names and v2.0 refs

## [2.0.2] - 2026-05-13

### Bug fixes

- use full action paths in reusable workflows and rename st-* to vrg-*
- use full action path in standards-compliance composite action
- use release/* branch prefix in version-bump-pr (#468)
- migrate from app-id to client-id for GitHub App token (#469)

### Chores

- bump version to 1.5.24

### Documentation

- update workflow README refs to vergil-actions v2.0

### Features

- rename to vergil-actions under vergil-project org (#464)

## [1.5.23] - 2026-05-11

### Chores

- bump version to 1.5.23

### Documentation

- update actions/index.md cross-references for new namespace

## [1.5.22] - 2026-05-11

### Chores

- bump version to 1.5.22
- archive 6 completed plans to docs/plans/completed/

### Documentation

- add design spec for actions/ namespace rationalization (#440)
- expand documentation section in namespace rationalization spec (#440)
- apply pushback review to namespace rationalization spec (#440)
- add implementation plan for actions/ namespace rationalization (#440)
- update action listing to new namespace (#440)
- rename and update action doc pages for new namespace (#440)
- update doc cross-references for new action namespace (#440)
- update nav entries for new action namespace (#440)

### Refactoring

- extract inline logic from reusable workflows into composite actions
- move actions to phase/domain/action namespace hierarchy (#440)
- update local action paths to new namespace (#440)
- update remote action refs to new namespace (#440)
- update action-to-action refs to new namespace (#440)
- rename registry-publish-command input to publish-command (#440)

## [1.5.21] - 2026-05-11

### Bug fixes

- verify tag is resolvable after push, resync if needed

### CI

- rename release caller key to version

### Chores

- bump version to 1.5.21

### Documentation

- add design spec for extracting workflow logic into composite actions
- add permissions note to registry-publish spec
- apply pushback review to extraction spec (#436)
- add implementation plan for extracting workflow logic (#436)
- decouple build audits from registry-publish gate (#436)
- add alignment review for workflow extraction (#436)

### Features

- switch all CI/CD container images from dev- to prod- prefix
- add container-prefix input to all reusable workflows, default to prod

### Refactoring

- align PR and issue templates with standard-tooling

## [1.5.20] - 2026-05-09

### Chores

- bump version to 1.5.20

## [1.5.19] - 2026-05-09

### Bug fixes

- simplify ops-github-config to use default failure notifications

### Chores

- bump version to 1.5.19

## [1.5.18] - 2026-05-09

### Chores

- bump version to 1.5.18

### Documentation

- sweep documentation for consistency with recent changes

### Features

- add ops-github-config reusable workflow (#424)

## [1.5.17] - 2026-05-09

### Bug fixes

- keep release job key until check name registry updates (#383)
- use system Python to avoid venv PATH shadowing (#418)

### Chores

- bump version to 1.5.17

### Documentation

- add design spec for system Python fix (#418)
- move spec to docs/specs/ (#418)

### Features

- add fleet-wide CI/CD workflow convention rollout script (#383)

## [1.5.16] - 2026-05-09

### Bug fixes

- make container-tag a required input in publish-release.yml
- make language/container-tag optional, add registry-publish input
- gate registry-specific steps behind registry-publish input
- use env vars in validation step to avoid expression injection

### Chores

- bump version to 1.5.16

### Documentation

- add implementation plan for registry-publish flag
- add design spec, updated plan, and pushback review for registry-publish flag

## [1.5.15] - 2026-05-09

### Bug fixes

- add GITHUB_PATH for st-* commands in self-install path (#403)

### Chores

- bump version to 1.5.15

### Documentation

- add CI/CD namespace convention design spec (#383)
- move spec to docs/specs/ per project convention
- add CI/CD namespace convention implementation plan (#383)
- add CI YAML standardization design spec (#387)
- combine #383 and #387 into single CI/CD workflow convention spec
- add workflow conventions README (#383)
- update site docs for CI/CD namespace convention (#383)
- update documentation for CI/CD workflow convention (#383)
- add st-* command availability normalization spec (#403)
- address pushback review for st-* normalization spec (#403)
- add st-* command normalization implementation plan (#403)

### Features

- rename ci-release.yml to ci-version-bump.yml (#383)
- update workflow name and ci.yml reference for ci-version-bump.yml (#383)
- rename publish-release.yml to cd-release.yml (#383)
- split publish-docs.yml into cd-docs.yml (workflow_call only) (#383)
- rename publish.yml to cd.yml umbrella with docs job (#383)

## [1.5.14] - 2026-05-08

### Bug fixes

- route pre-deploy-command through env var to avoid shell injection
- containerize publish workflows to use dev-base images
- set default shell to bash for containerized publish workflows

### Chores

- prepare release 1.5.11
- bump version to 1.5.12
- add publish section to standard-tooling.toml
- fleet-wide config and workflow cleanup
- shorten issue template header comments to fit yamllint line-length

### Documentation

- add design spec and plan for Docker CI centralization (#378)

### Features

- add publish-docs.yml dual-trigger reusable workflow, delete docs.yml

### Refactoring

- auto-derive release title and notes from repo metadata
- remove domain-specific checkout-common inputs
- use st-version bump instead of regex substitution
- derive all inputs from standard-tooling.toml, zero required caller inputs
- use st-version and auto-derived defaults in bespoke publish workflow

## [1.5.11] - 2026-05-07

### Bug fixes

- remove uv run prefix from st-docker-run invocations

### Chores

- prepare release 1.5.10
- bump version to 1.5.11
- decommission st-validate-local remnants

## [1.5.10] - 2026-05-06

### Bug fixes

- run uv sync in standard-tooling self-install path

### Chores

- prepare release 1.5.9
- bump version to 1.5.10

### Features

- add container-tag input, make common job container overridable
- add container-suffix and container-tag inputs for standards job
- add container-suffix and container-tag inputs for version-bump job

## [1.5.9] - 2026-05-06

### Bug fixes

- complete .venv/bin PATH fix for all st-* invocations and add GHAS required checks

### Chores

- prepare release 1.5.8
- bump version to 1.5.9

## [1.5.8] - 2026-05-06

### Bug fixes

- prepend .venv/bin to PATH before st-validate calls

### Chores

- prepare release 1.5.6
- merge main into release/1.5.7
- prepare release 1.5.7
- bump version to 1.5.8

## [1.5.7] - 2026-05-06

### Chores

- bump version to 1.5.7

## [1.5.6] - 2026-05-06

### Bug fixes

- skip uv tool install when consumer repo is standard-tooling

### Chores

- prepare release 1.5.5
- bump version to 1.5.6

## [1.5.5] - 2026-05-06

### Bug fixes

- install dev dependencies in lint and typecheck jobs
- install dev dependencies in test and audit reusable workflows
- rename step from Install dev dependencies to Install dependencies

### Chores

- prepare release 1.5.4
- bump version to 1.5.5

## [1.5.4] - 2026-05-06

### Bug fixes

- use relative action refs in CI workflows, freeze to tagged refs at publish time

### Chores

- prepare release 1.5.3
- bump version to 1.5.4

## [1.5.3] - 2026-05-05

### Bug fixes

- remove || true from yamllint in ci-quality.yml
- remove || true from markdownlint, hadolint, and actionlint
- fix linter violations exposed by removing || true
- fix markdownlint violations in CI workflow reset design spec
- add safe.directory for container-based CI in version-divergence action
- add safe.directory to setup action for container-based CI
- always install standard-tooling from pinned tag, never skip

### CI

- pass container-suffix to ci-quality for shell language

### Chores

- prepare release 1.5.2
- bump version to 1.5.3

### Documentation

- add design spec for CI workflow reset and unified validation
- apply pushback review to CI workflow reset design
- add implementation plan for CI workflow reset
- add st-version as explicit Phase 1 task in CI workflow reset plan
- apply alignment review fixes to CI workflow reset plan and spec

### Features

- implement ci-quality.yml with st-validate dispatch
- implement ci-test.yml with st-validate dispatch
- implement ci-audit.yml with st-validate dispatch
- implement ci-release.yml with st-version version-divergence gate
- add reusable setup/standard-tooling action and use it in all workflows

## [1.5.2] - 2026-05-05

### Bug fixes

- pin astral-sh/setup-uv to v8.1.0

### Chores

- prepare release 1.5.1
- bump version to 1.5.2

### Documentation

- add design spec for publish and docs workflow rationalization
- apply pushback review to publish/docs rationalization spec
- add implementation plan for publish and docs rationalization
- apply alignment review fixes to publish/docs rationalization plan

## [1.5.1] - 2026-05-05

### Bug fixes

- replace pip install uv with astral-sh/setup-uv
- remove dead st-config.toml fallback from ci-security.yml

### Chores

- prepare release 1.5.0
- bump version to 1.5.1
- align with st-github-config enforcement

### Documentation

- add reusable workflows nav section to mkdocs config
- add reusable workflows overview page
- add ci-security workflow reference page
- add ci-quality workflow reference page
- add ci-audit workflow reference page
- add ci-test workflow reference page
- add ci-release workflow reference page
- update home page for v1.5 reusable workflow redesign
- update getting-started for v1.5 reusable workflow consumption
- update CI gates section for v1.5 reusable workflows
- sweep action reference pages for v1.5 accuracy

### Features

- add p/ci base ruleset and auto-detect p/dockerfile, p/github-actions

## [1.5.0] - 2026-05-04

### Chores

- prepare release 1.4.8
- bump version to 1.4.9

### Features

- add five reusable CI workflows for canonical check names

## [1.4.8] - 2026-05-03

### Bug fixes

- skip language ruleset when not found in registry (#303) (#304)

### Chores

- prepare release 1.4.7
- bump version to 1.4.8
- add memory management policy (#299)
- remove repo-local markdownlint config (standard-tooling#476) (#302)

### Documentation

- remove stale include directives and update docs/repository-standards.md references

## [1.4.7] - 2026-05-01

### Chores

- prepare release 1.4.6
- bump version to 1.4.7
- remove legacy st-config.toml
- update ci.yml install step to read standard-tooling.toml

### Refactoring

- replace pip install with uv tool install and remove guard patterns
- remove runtime tool installs now that dev-base image provides them

## [1.4.6] - 2026-04-30

### Chores

- prepare release 1.4.5
- bump version to 1.4.6
- migrate ci-security.yml install step to standard-tooling.toml

## [1.4.5] - 2026-04-30

### Chores

- prepare release 1.4.4
- bump version to 1.4.5
- strip config sections from repository-standards.md
- read version tag from standard-tooling.toml with st-config.toml fallback

## [1.4.4] - 2026-04-29

### Bug fixes

- self-install standard-tooling when not on PATH

### Chores

- prepare release 1.4.3
- bump version to 1.4.4
- seed standard-tooling.toml

## [1.4.3] - 2026-04-29

### Chores

- prepare release 1.4.2
- bump version to 1.4.3

### Refactoring

- slim to PR-only checks, remove repo-profile and markdown validation

## [1.4.2] - 2026-04-29

### Bug fixes

- install standard-tooling in standards-compliance job (#255)
- add standard-tooling install to local ci.yml standards job (#255)

### Chores

- prepare release 1.4.1
- bump version to 1.4.2
- bootstrap st-config.toml for cache-first docker workflow

### Documentation

- comprehensive documentation review for consistency after v1.4.x changes

## [1.4.1] - 2026-04-28

### Chores

- prepare release 1.4.0
- bump version to 1.4.1
- bump CI action pins: create-github-app-token v3, attest-build-provenance v4
- align local validation with container-based st-docker-run workflow

### Features

- add CI check to reject auto-close linkage keywords in PR bodies

## [1.4.0] - 2026-04-28

### Chores

- prepare release 1.3.3
- bump version to 1.3.4
- bump version to 1.4.0

## [1.3.3] - 2026-04-28

### Chores

- prepare release 1.3.1
- merge main into release/1.3.2
- prepare release 1.3.2
- bump version to 1.3.3
- remove add-to-project.yml workflow
- bump aquasec/trivy from 0.69.2 to 0.70.0

## [1.3.2] - 2026-04-27

### Bug fixes

- use Issues API instead of Search API for tracking-issue lookup

## [1.3.1] - 2026-04-27

### Chores

- prepare release 1.3.0
- merge main into release/1.3.0
- prepare release 1.3.0
- bump version to 1.3.1

### Features

- print findings table to stdout in addition to SARIF

## [1.3.0] - 2026-04-27

### Bug fixes

- inline helper python scripts to fix container-job failure (#204)
- add safe.directory '*' for container workspace ownership (#206)
- use App token throughout publish.yml so freeze-refs commit can be pushed

### Chores

- prepare release 1.2.1
- bump version to 1.2.2
- vendor .githooks gate + .yamllint; clean stale CLAUDE.md refs (#208)

### Documentation

- clarify install paths and verification error (#202)

### Features

- freeze internal @develop refs at tag-cut time

## [1.2.1] - 2026-04-24

### Bug fixes

- use env vars + quoted heredoc in version-bump-pr Update step

### Chores

- merge main into release/1.2.0
- prepare release 1.2.0
- bump version to 1.2.1

### Release

- 1.1.3 (#190)

## [1.2.0] - 2026-04-24

### Chores

- bump version to 1.1.4 (#191)

### Features

- drop auto-merge from version-bump-pr composite (bump 1.2.0) (#193)

## [1.1.3] - 2026-04-23

### Bug fixes

- pin markdownlint-cli@0.41.0, add run-codeql flag (#172) (#173)
- rename dev-docs container references to dev-base (#182)
- stabilize version-bump-pr back-merge and docs-deploy container cwd (#188)

### CI

- remove standard-tooling setup hacks from standards-compliance (#179)

### Chores

- prepare release 1.1.2
- bump version to 1.1.3
- update toolchain dependencies for next development cycle (#162)
- install standard-tooling plugin via marketplace (#165)
- strip CLAUDE.md boilerplate now covered by plugin (#167)
- add .markdownlintignore for auto-generated files (#190) (#170)
- exclude AGENTS.md and CLAUDE.md from markdownlint
- update CLAUDE.md for docker-only standard-tooling (#178)
- ban MEMORY.md usage in CLAUDE.md (#180)

### Features

- add shared publish-release reusable workflow (#163)
- make docs-deploy container-aware (#174)
- adopt git worktree convention for parallel AI agent development (#184)

## [1.1.2] - 2026-03-01

### Bug fixes

- fix version-bump regex and correct VERSION to 1.1.2 (#136)
- create placeholder releases/index.md when no releases exist (#148)
- install Trivy binary directly to avoid setup-trivy cache fallback failure (#152)
- use setup-trivy with cache disabled instead of manual binary download (#153)
- replace aquasecurity GitHub actions with Docker-based Trivy execution (#154)

### Chores

- bump version to 1.1.2
- deploy standardized issue template (#156)

### Documentation

- document run-standards and run-security two-flag pattern (#138)
- add Rust Library to required checks matrix (#142)
- add ci: type-check to required checks matrix (#143)
- update tag protection ruleset docs for rolling tag support (#158)

### Features

- add rolling vX.Y minor tags to tag-and-release action (#149)

## [1.1.1] - 2026-02-26

### Bug fixes

- bootstrap standards documentation
- add autobuild step for compiled language support
- sync shared tooling to v1.0.2
- sync lint scripts from standards-and-conventions (#28)
- pass release notes via env var to prevent shell injection (#44)
- replace mapfile with bash 3.2-compatible alternative (#49)
- set dev as default version when no default exists (#57)
- remove redundant close/reopen cycle (#66)
- update add-to-project action to v1.0.2 (#69)
- resolve event-payload race in version-bump-pr issue linkage (#73)
- add diagnostics to version-bump-pr tracking issue resolution (#81)
- handle missing version on main in version-divergence check (#87)
- search all issue states when resolving bump PR tracking issue (#95)
- add semgrep-language input for Go compatibility (#101)
- preserve severity filter in SARIF output for Trivy scans (#123)
- install pyyaml when mike-command is not mike (#128)
- correct corrupted VERSION file to 1.1.1 (#133)

### CI

- add publish workflow for tag, release, and version bump (#131)

### Chores

- bootstrap standard-actions (#2)
- sync shared tooling to v1.0.5 (#35)
- remove push trigger from CI workflow (#55)
- sync standard-tooling v1.1.4 (#64)
- standardize workflow files (#75)
- remove SonarCloud and Code Climate integrations (#96)
- upgrade CodeQL Action from v3 to v4 (#97)
- add changelog and release notes infrastructure (#104)
- stage changelog and release notes in docs-deploy action (#105)
- reposition Releases in MkDocs nav (#107)
- add tier-1 validation scripts (#113)
- restructure Releases nav with TOC hiding, semver sort, and version injection (#126)
- prepare release 1.1.0
- bump version to 1.1.1

### Documentation

- align standards entrypoint with repo type
- add repository bootstrap guide
- ban MEMORY.md usage in CLAUDE.md (#48)
- ban heredocs in shell commands (#50)
- update CI gate docs to reflect actual state (#56)
- add repository rulesets documentation (#58)
- add branch targeting guidance to rulesets page (#59)
- add branch targeting guidance to rulesets page (#60)
- add repository configuration documentation (#76)
- update SonarCloud documentation with lessons learned and beta status (#83)
- document version matrix for unit and integration tests, add Ruby column, explain duplicate security checks (#88)
- replace stale script references with st-* commands (#94)
- add publish workflow ordering guide (#117)
- fix secret gate example in publish workflow guide (#118)
- add version bump PR guidance to publish workflow guide (#121)

### Features

- add initial composite actions for docs-only detection, standards compliance, and Python setup (#10)
- exempt docs/site from structural markdown checks (#11)
- add CodeQL SAST composite action
- add Trivy and Semgrep composite actions for Tier 2 security tooling
- add shared tooling staleness gate and sync scripts
- add CI workflow, CLAUDE.md, and repository infrastructure (#24)
- add add-to-project workflow for standards project
- add ci and build to allowed conventional commit types (#32)
- add composite action for MkDocs/mike deployment (#33)
- add VERSION file for release automation (#37)
- add reusable composite actions for tag-and-release, version-bump-pr, and version-divergence (#41)
- add category prefixes to CI job names (#45)
- adopt validate_local.sh dispatch architecture (#51)
- add MkDocs documentation site with action reference and CI gate specs (#53)
- migrate to PATH-based standard-tooling consumption (#77)
- add SonarCloud composite action (#82)
- add Code Climate (Qlty) coverage upload action (#84)
- add reusable security and standards workflow (#99)
- add sarif-category input for unique SARIF uploads (#115)
- add trivyignores input for suppressing known-acceptable CVEs (#120)

### Refactoring

- remove commit message validation from CI (#78)
- remove docs-only-detect action and CI special-casing (#111)
