# OpenSSF Scorecard snapshots

Point-in-time [OpenSSF Scorecard](https://github.com/ossf/scorecard) captures for
this repository. A Scorecard result is a report of security posture at one
commit, not an open work item — so we capture it here as dated snapshots and
re-run it on a cadence, rather than accreting findings in the issue tracker.

**Remediation is tracked separately.** This document is the *record*, not the
work. The actual OpenSSF hardening work lives in epic
[vergil-project/.github#54](https://github.com/vergil-project/.github/issues/54),
tracking issue
[vergil-project/vergil-tooling#828](https://github.com/vergil-project/vergil-tooling/issues/828).

## How to add a snapshot

Re-run the Scorecard from a checkout of this repo and append a new dated section
at the top of [Snapshots](#snapshots) (newest first), then add a row to the
[trend table](#trend):

```bash
vrg-scorecard --repo=github.com/vergil-project/vergil-actions --show-details
```

Record, for each snapshot: the aggregate score, the evaluated commit SHA, the
Scorecard version, the per-check table, and the detailed findings. Cadence:
roughly quarterly, or after any deliberate hardening change worth measuring.

## Trend

| Date | Aggregate | Commit | Scorecard |
|------|-----------|--------|-----------|
| 2026-08-12 | 5.5 / 10 | `bbaccdd496ac` | v5.5.0 |
| 2026-05-19 | 5.5 / 10 | `eabd7147c51b` | v5.5.0 |

Score legend: 🟢 10/10 · 🔴 0–9/10 (needs work) · ⚪ -1/10 (not applicable /
not detected).

## Snapshots

### 2026-08-12

**Aggregate score:** 5.5 / 10
**Commit:** `bbaccdd496acb373b48d22a68c5a901dd4f7c9f6`
**Scorecard version:** v5.5.0
**Tracking issue:**
[vergil-project/vergil-tooling#828](https://github.com/vergil-project/vergil-tooling/issues/828)

#### Changes since the 2026-05-19 baseline

The aggregate held at 5.5 — **no check changed score**. The only movement is in
sample sizes and detail counts, not posture:

- **Code-Review** 0/19 (was 0/13) and **CI-Tests** 19/19 (was 15/15) — same
  scores, larger merged-PR sample.
- **Maintained** stayed 10/10, now on 30 commits and 15 issue activity (was 30
  and 30) in the trailing 90 days.
- **Pinned-Dependencies** stayed 0/10 with a larger warning set (40 vs. the
  baseline's ~38) as more workflow files were added
  (`cd-docs-refresh.yml`, `ci-docs.yml`, `epic-rollup.yml`,
  `ops-epic-rollup.yml`, `ops-epic-sweep.yml`, `ops-github-config.yml`).

All other checks are unchanged from the baseline.

#### Scores by check

| Score | Check | Reason |
|-------|-------|--------|
| ⚪ -1/10 | Packaging | packaging workflow not detected |
| ⚪ -1/10 | Signed-Releases | no releases found |
| 🔴 0/10 | CII-Best-Practices | no effort to earn an OpenSSF best practices badge detected |
| 🔴 0/10 | Code-Review | Found 0/19 approved changesets |
| 🔴 0/10 | Contributors | project has 0 contributing companies or organizations |
| 🔴 0/10 | Dependency-Update-Tool | no update tool detected |
| 🔴 0/10 | Fuzzing | project is not fuzzed |
| 🔴 0/10 | Pinned-Dependencies | dependency not pinned by hash detected |
| 🔴 0/10 | Token-Permissions | detected GitHub workflow tokens with excessive permissions |
| 🔴 4/10 | Branch-Protection | branch protection is not maximal on development and all release branches |
| 🟢 10/10 | Binary-Artifacts | no binaries found in the repo |
| 🟢 10/10 | CI-Tests | 19 out of 19 merged PRs checked by a CI test |
| 🟢 10/10 | Dangerous-Workflow | no dangerous workflow patterns detected |
| 🟢 10/10 | License | license file detected (MIT) |
| 🟢 10/10 | Maintained | 30 commits and 15 issue activity in the last 90 days |
| 🟢 10/10 | SAST | SAST tool is run on all commits |
| 🟢 10/10 | Security-Policy | security policy file detected |
| 🟢 10/10 | Vulnerabilities | 0 existing vulnerabilities detected |

#### Detailed findings

##### Packaging (-1/10)

**Reason:** packaging workflow not detected

**Warnings:**
- `no GitHub/GitLab publishing workflow detected.`

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#packaging

##### Signed-Releases (-1/10)

**Reason:** no releases found

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#signed-releases

##### CII-Best-Practices (0/10)

**Reason:** no effort to earn an OpenSSF best practices badge detected

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#cii-best-practices

##### Code-Review (0/10)

**Reason:** Found 0/19 approved changesets -- score normalized to 0

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#code-review

##### Contributors (0/10)

**Reason:** project has 0 contributing companies or organizations -- score normalized to 0

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#contributors

##### Dependency-Update-Tool (0/10)

**Reason:** no update tool detected

**Warnings:**
- `no dependency update tool configurations found`

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#dependency-update-tool

##### Fuzzing (0/10)

**Reason:** project is not fuzzed

**Warnings:**
- `no fuzzer integrations found`

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#fuzzing

##### Pinned-Dependencies (0/10)

**Reason:** dependency not pinned by hash detected -- score normalized to 0

**Warnings:**
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-docs-refresh.yml:38`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd-docs.yml:33`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd-release.yml:95`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd.yml:31`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd.yml:37`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:56`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:77`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:121`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:138`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:141`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-docs.yml:25`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:48`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:65`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:83`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:116`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:139`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:172`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:192`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:195`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:85`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:100`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:116`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:128`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:145`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:171`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:196`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:199`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-test.yml:66`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-test.yml:110`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-test.yml:127`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-test.yml:130`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-test.yml:45`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-version-bump.yml:43`
- `third-party GitHubAction not pinned by hash: .github/workflows/epic-rollup.yml:20`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-epic-rollup.yml:37`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-epic-rollup.yml:47`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-epic-sweep.yml:42`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-epic-sweep.yml:53`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-github-config.yml:29`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-github-config.yml:35`

<details><summary>Info details (2 items)</summary>

- `0 out of 38 GitHub-owned GitHubAction dependencies pinned`
- `0 out of 2 third-party GitHubAction dependencies pinned`

Remediation helper (pin by hash): https://app.stepsecurity.io/securerepo

</details>

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#pinned-dependencies

##### Token-Permissions (0/10)

**Reason:** detected GitHub workflow tokens with excessive permissions

**Warnings:**
- `jobLevel 'contents' permission set to 'write': .github/workflows/cd-docs-refresh.yml:40`
- `jobLevel 'contents' permission set to 'write': .github/workflows/cd-release.yml:85`
- `jobLevel 'contents' permission set to 'write': .github/workflows/cd.yml:78`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:81`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:112`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:141`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci.yml:32`
- `topLevel 'contents' permission set to 'write': .github/workflows/cd-docs-refresh.yml:31`
- `topLevel 'contents' permission set to 'write': .github/workflows/cd-docs.yml:20`
- `no topLevel permission defined: .github/workflows/cd-release.yml:1`
- `topLevel 'contents' permission set to 'write': .github/workflows/cd.yml:9`
- `no topLevel permission defined: .github/workflows/ci-audit.yml:1`
- `no topLevel permission defined: .github/workflows/ci-quality.yml:1`
- `topLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:62`
- `no topLevel permission defined: .github/workflows/ci-test.yml:1`
- `no topLevel permission defined: .github/workflows/ci-version-bump.yml:1`
- `topLevel 'security-events' permission set to 'write': .github/workflows/ci.yml:8`

<details><summary>Info details (21 items)</summary>

- `jobLevel 'actions' permission set to 'read': .github/workflows/cd-release.yml:92`
- `jobLevel 'actions' permission set to 'read': .github/workflows/ci-security.yml:82`
- `jobLevel 'contents' permission set to 'read': .github/workflows/ci-security.yml:80`
- `jobLevel 'contents' permission set to 'read': .github/workflows/ci-security.yml:111`
- `jobLevel 'actions' permission set to 'read': .github/workflows/ci-security.yml:113`
- `jobLevel 'contents' permission set to 'read': .github/workflows/ci-security.yml:140`
- `jobLevel 'actions' permission set to 'read': .github/workflows/ci-security.yml:142`
- `jobLevel 'contents' permission set to 'read': .github/workflows/ci-security.yml:192`
- `jobLevel 'actions' permission set to 'read': .github/workflows/ci-security.yml:193`
- `jobLevel 'contents' permission set to 'read': .github/workflows/ci.yml:31`
- `jobLevel 'actions' permission set to 'read': .github/workflows/ci.yml:33`
- `jobLevel 'contents' permission set to 'read': .github/workflows/epic-rollup.yml:22`
- `topLevel 'contents' permission set to 'read': .github/workflows/ci-docs.yml:16`
- `topLevel 'contents' permission set to 'read': .github/workflows/ci-security.yml:61`
- `topLevel 'actions' permission set to 'read': .github/workflows/ci-security.yml:63`
- `topLevel 'contents' permission set to 'read': .github/workflows/ci.yml:7`
- `topLevel 'actions' permission set to 'read': .github/workflows/ci.yml:9`
- `topLevel 'contents' permission set to 'read': .github/workflows/epic-rollup.yml:16`
- `topLevel 'contents' permission set to 'read': .github/workflows/ops-epic-rollup.yml:27`
- `topLevel 'contents' permission set to 'read': .github/workflows/ops-epic-sweep.yml:32`
- `topLevel 'contents' permission set to 'read': .github/workflows/ops-github-config.yml:19`

</details>

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#token-permissions

##### Branch-Protection (4/10)

**Reason:** branch protection is not maximal on development and all release branches

**Warnings:**
- `branch 'develop' does not require approvers`
- `codeowners review is not required on branch 'develop'`
- `'last push approval' is disabled on branch 'develop'`

<details><summary>Info details (7 items)</summary>

- `'allow deletion' disabled on branch 'develop'`
- `'force pushes' disabled on branch 'develop'`
- `'branch protection settings apply to administrators' is required to merge on branch 'develop'`
- `'stale review dismissal' is required to merge on branch 'develop'`
- `'up-to-date branches' is required to merge on branch 'develop'`
- `status check found to merge onto on branch 'develop'`
- `PRs are required in order to make changes on branch 'develop'`

</details>

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#branch-protection

---

### 2026-05-19 (baseline)

**Aggregate score:** 5.5 / 10
**Commit:** `eabd7147c51b`
**Scorecard version:** v5.5.0
**Tracking issue:**
[vergil-project/vergil-tooling#828](https://github.com/vergil-project/vergil-tooling/issues/828)

> First captured snapshot, preserved from the tracking issue
> ([#508](https://github.com/vergil-project/vergil-actions/issues/508)).

#### Scores by check

| Score | Check | Reason |
|-------|-------|--------|
| ⚪ -1/10 | Packaging | packaging workflow not detected |
| ⚪ -1/10 | Signed-Releases | no releases found |
| 🔴 0/10 | CII-Best-Practices | no effort to earn an OpenSSF best practices badge detected |
| 🔴 0/10 | Code-Review | Found 0/13 approved changesets |
| 🔴 0/10 | Contributors | project has 0 contributing companies or organizations |
| 🔴 0/10 | Dependency-Update-Tool | no update tool detected |
| 🔴 0/10 | Fuzzing | project is not fuzzed |
| 🔴 0/10 | Pinned-Dependencies | dependency not pinned by hash detected |
| 🔴 0/10 | Token-Permissions | detected GitHub workflow tokens with excessive permissions |
| 🔴 4/10 | Branch-Protection | branch protection is not maximal on development and all release branches |
| 🟢 10/10 | Binary-Artifacts | no binaries found in the repo |
| 🟢 10/10 | CI-Tests | 15 out of 15 merged PRs checked by a CI test |
| 🟢 10/10 | Dangerous-Workflow | no dangerous workflow patterns detected |
| 🟢 10/10 | License | license file detected |
| 🟢 10/10 | Maintained | 30 commit(s) and 30 issue activity found in the last 90 days |
| 🟢 10/10 | SAST | SAST tool is run on all commits |
| 🟢 10/10 | Security-Policy | security policy file detected |
| 🟢 10/10 | Vulnerabilities | 0 existing vulnerabilities detected |

#### Detailed findings

##### Packaging (-1/10)

**Reason:** packaging workflow not detected

**Warnings:**
- `no GitHub/GitLab publishing workflow detected.`

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#packaging

##### Signed-Releases (-1/10)

**Reason:** no releases found

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#signed-releases

##### CII-Best-Practices (0/10)

**Reason:** no effort to earn an OpenSSF best practices badge detected

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#cii-best-practices

##### Code-Review (0/10)

**Reason:** Found 0/13 approved changesets -- score normalized to 0

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#code-review

##### Contributors (0/10)

**Reason:** project has 0 contributing companies or organizations -- score normalized to 0

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#contributors

##### Dependency-Update-Tool (0/10)

**Reason:** no update tool detected

**Warnings:**
- `no dependency update tool configurations found`

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#dependency-update-tool

##### Fuzzing (0/10)

**Reason:** project is not fuzzed

**Warnings:**
- `no fuzzer integrations found`

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#fuzzing

##### Pinned-Dependencies (0/10)

**Reason:** dependency not pinned by hash detected -- score normalized to 0

**Warnings:**
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd-docs.yml:33`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-docs.yml:38`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-docs.yml:48`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd-release.yml:87`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-release.yml:92`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-release.yml:99`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-release.yml:132`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-release.yml:150`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd-release.yml:174`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd-release.yml:181`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd.yml:32`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/cd.yml:38`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd.yml:70`
- `third-party GitHubAction not pinned by hash: .github/workflows/cd.yml:76`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:36`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-audit.yml:39`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:39`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:42`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:56`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:59`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:77`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-quality.yml:80`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:86`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-security.yml:89`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:102`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-security.yml:105`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:55`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-security.yml:58`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-security.yml:61`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-security.yml:71`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-security.yml:74`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-test.yml:36`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-test.yml:39`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ci-version-bump.yml:39`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-version-bump.yml:44`
- `third-party GitHubAction not pinned by hash: .github/workflows/ci-version-bump.yml:47`
- `GitHub-owned GitHubAction not pinned by hash: .github/workflows/ops-github-config.yml:15`
- `third-party GitHubAction not pinned by hash: .github/workflows/ops-github-config.yml:18`

<details><summary>Info details (2 items)</summary>

- `0 out of  16 GitHub-owned GitHubAction dependencies pinned`
- `0 out of  22 third-party GitHubAction dependencies pinned`

</details>

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#pinned-dependencies

##### Token-Permissions (0/10)

**Reason:** detected GitHub workflow tokens with excessive permissions

**Warnings:**
- `jobLevel 'contents' permission set to 'write': .github/workflows/cd-release.yml:81`
- `jobLevel 'contents' permission set to 'write': .github/workflows/cd.yml:84`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:68`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:83`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:99`
- `jobLevel 'security-events' permission set to 'write': .github/workflows/ci.yml:26`
- `topLevel 'contents' permission set to 'write': .github/workflows/cd-docs.yml:20`
- `no topLevel permission defined: .github/workflows/cd-release.yml:1`
- `topLevel 'contents' permission set to 'write': .github/workflows/cd.yml:9`
- `no topLevel permission defined: .github/workflows/ci-audit.yml:1`
- `no topLevel permission defined: .github/workflows/ci-quality.yml:1`
- `topLevel 'security-events' permission set to 'write': .github/workflows/ci-security.yml:45`
- `no topLevel permission defined: .github/workflows/ci-test.yml:1`
- `no topLevel permission defined: .github/workflows/ci-version-bump.yml:1`
- `topLevel 'security-events' permission set to 'write': .github/workflows/ci.yml:8`

<details><summary>Info details (4 items)</summary>

- `jobLevel 'contents' permission set to 'read': .github/workflows/ci.yml:25`
- `topLevel 'contents' permission set to 'read': .github/workflows/ci-security.yml:44`
- `topLevel 'contents' permission set to 'read': .github/workflows/ci.yml:7`
- `topLevel 'contents' permission set to 'read': .github/workflows/ops-github-config.yml:7`

</details>

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#token-permissions

##### Branch-Protection (4/10)

**Reason:** branch protection is not maximal on development and all release branches

**Warnings:**
- `branch 'develop' does not require approvers`
- `codeowners review is not required on branch 'develop'`
- `'last push approval' is disabled on branch 'develop'`

<details><summary>Info details (7 items)</summary>

- `'allow deletion' disabled on branch 'develop'`
- `'force pushes' disabled on branch 'develop'`
- `'branch protection settings apply to administrators' is required to merge on branch 'develop'`
- `'stale review dismissal' is required to merge on branch 'develop'`
- `'up-to-date branches' is required to merge on branch 'develop'`
- `status check found to merge onto on branch 'develop'`
- `PRs are required in order to make changes on branch 'develop'`

</details>

**Documentation:** https://github.com/ossf/scorecard/blob/c395761df6afe1a69e476bc60a013a94bcbc153f/docs/checks.md#branch-protection
