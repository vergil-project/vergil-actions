#!/usr/bin/env bash
#
# Test the key boundary in ops-upstream-refresh.yml (epic
# vergil-project/.github#1168, spec §6 and §6.3).
#
# The automation App's private key never shares a runner with the work: the
# caller's upstream-refresh hook and anything it installs or loads. So the
# workflow runs as two jobs, each on a fresh runner. `prepare` runs the hook
# with no secrets and a read-only GITHUB_TOKEN and hands on a patch as an
# artifact. `publish` holds the App's credentials, on the one step that runs
# `vrg-upstream-refresh publish`, and never runs the hook. A wiring mistake
# that put a secret on prepare, on a job's env or on another publish step
# would break the boundary without any run failing, so this test is the
# guard.
#
# Framework-free and developer-runnable: `bash key-boundary.test.sh`. CI runs
# it from .github/workflows/smoke-setup-vergil.yml. It needs `yq` (mikefarah
# v4, preinstalled on GitHub's ubuntu runners) and touches no network.
#
# The rules, checked on ops-upstream-refresh.yml:
#   * the jobs are exactly prepare and publish, and publish needs prepare;
#   * secrets.APP_CLIENT_ID and secrets.APP_PRIVATE_KEY appear only as
#     VRG_AUTOMATION_CLIENT_ID and VRG_AUTOMATION_PRIVATE_KEY in the `env` of
#     publish's step that runs `vrg-upstream-refresh publish`; no other value
#     names `secrets` and no job passes `secrets:` on;
#   * both jobs have `permissions: contents: read`, and prepare sets no
#     VRG_AUTOMATION_* variable anywhere;
#   * no workflow-level or job-level `env` sets VRG_AUTOMATION_APP;
#   * each job's first step is the develop guard: it reads github.ref as REF
#     and vars.VRG_AUTOMATION_APP as AUTOMATION_APP, and fails unless REF is
#     refs/heads/develop and AUTOMATION_APP is non-empty;
#   * no job and no step has an `if:`;
#   * prepare has timeout-minutes 30 and publish 140;
#   * both checkouts set persist-credentials: false;
#   * prepare's tool step takes GH_TOKEN from github.token, the read-only
#     token;
#   * the workflow-level concurrency group is
#     `${{ github.repository }}/upstream-refresh`, never cancelled;
#   * create-github-app-token and `gh auth setup-git` are absent.
# Fixture copies of the workflow, each broken one way, check that each rule
# catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
real="${repo_root}/.github/workflows/ops-upstream-refresh.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'key-boundary.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$real" ]; then
  printf 'key-boundary.test.sh: missing %s\n' "$real" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

fail_case() {
  printf 'not ok - %s: %s\n' "$1" "$2" >&2
  fail=$((fail + 1))
}

pass_case() {
  printf 'ok - %s\n' "$1"
  pass=$((pass + 1))
}

# check_guard <workflow file> <job> — print a violation when the job's first
# step is not the develop guard.
check_guard() {
  local wf="$1" job="$2" first ref app run uses
  first=".jobs.\"${job}\".steps[0]"
  ref="$(yq -r "${first}.env.REF // \"\"" "$wf")"
  app="$(yq -r "${first}.env.AUTOMATION_APP // \"\"" "$wf")"
  run="$(yq -r "${first}.run // \"\"" "$wf")"
  uses="$(yq -r "${first}.uses // \"\"" "$wf")"
  # shellcheck disable=SC2016 # literal GitHub Actions expressions and shell tests
  if [ -n "$uses" ] ||
    [ "$ref" != '${{ github.ref }}' ] ||
    [ "$app" != '${{ vars.VRG_AUTOMATION_APP }}' ] ||
    [[ "$run" != *'[ "${REF}" != "refs/heads/develop" ]'* ]] ||
    [[ "$run" != *'[ -z "${AUTOMATION_APP}" ]'* ]]; then
    printf '%s: the first step is not the develop guard\n' "$job"
  fi
}

# violations <workflow file> — print one line per rule the workflow breaks,
# nothing when it keeps them all.
violations() {
  local wf="$1" jobs needs pub_idx path value expected job var
  local timeout perms persist count

  jobs="$(yq -r '(.jobs // {}) | keys | join(",")' "$wf")"
  if [ "$jobs" != "prepare,publish" ]; then
    printf 'the jobs are not exactly prepare and publish: %s\n' "$jobs"
    return 0
  fi
  needs="$(yq -r '.jobs.publish.needs // "" | [.] | flatten | join(",")' "$wf")"
  if [ "$needs" != "prepare" ]; then
    printf 'publish does not need prepare: %s\n' "${needs:-<unset>}"
  fi

  # The publish step: the one step of publish that runs the tool's publish
  # mode. Its env is the only place the App's credentials may appear.
  count="$(yq -r '[.jobs.publish.steps[] | select((.run // "") | test("vrg-upstream-refresh publish"))] | length' "$wf")"
  pub_idx="$(yq -r '.jobs.publish.steps | to_entries | .[]
    | select((.value.run // "") | test("vrg-upstream-refresh publish")) | .key' "$wf" | head -n 1)"
  if [ "$count" != "1" ]; then
    printf 'publish has %s steps running vrg-upstream-refresh publish, not 1\n' "$count"
  fi
  if [ "$count" = "1" ] && [ -n "$(yq -r ".jobs.publish.steps[${pub_idx}].uses // \"\"" "$wf")" ]; then
    printf 'publish step %s runs the tool and also uses an action\n' "$pub_idx"
  fi

  # Every string value that names secrets, wherever it is (comments are not
  # values). Context names are case-insensitive, so the match is too.
  while IFS=$'\t' read -r path value; do
    [ -n "$path" ] || continue
    case "$path" in
      "jobs.publish.steps.${pub_idx:-x}.env.VRG_AUTOMATION_CLIENT_ID")
        # shellcheck disable=SC2016 # a literal GitHub Actions expression
        expected='${{ secrets.APP_CLIENT_ID }}'
        ;;
      "jobs.publish.steps.${pub_idx:-x}.env.VRG_AUTOMATION_PRIVATE_KEY")
        # shellcheck disable=SC2016 # a literal GitHub Actions expression
        expected='${{ secrets.APP_PRIVATE_KEY }}'
        ;;
      *)
        printf 'secrets referenced outside the publish step env: %s: %s\n' "$path" "$value"
        continue
        ;;
    esac
    if [ "$value" != "$expected" ]; then
      printf '%s is not %s: %s\n' "$path" "$expected" "$value"
    fi
  done < <(yq -r '.. | select(tag == "!!str" and test("(?i)(^|[^A-Za-z0-9_])secrets([^A-Za-z0-9_]|$)"))
    | [(path | join(".")), .] | @tsv' "$wf")
  if [ "$count" = "1" ]; then
    for var in VRG_AUTOMATION_CLIENT_ID VRG_AUTOMATION_PRIVATE_KEY VRG_AUTOMATION_APP; do
      if [ "$(yq -r ".jobs.publish.steps[${pub_idx}].env | has(\"${var}\")" "$wf")" != "true" ]; then
        printf 'the publish step does not set %s\n' "$var"
      fi
    done
    # shellcheck disable=SC2016 # a literal GitHub Actions expression
    if [ "$(yq -r ".jobs.publish.steps[${pub_idx}].env.VRG_AUTOMATION_APP // \"\"" "$wf")" != '${{ vars.VRG_AUTOMATION_APP }}' ]; then
      printf 'the publish step VRG_AUTOMATION_APP is not ${{ vars.VRG_AUTOMATION_APP }}\n'
    fi
  fi
  if [ "$(yq -r '[.jobs | .. | select(tag == "!!map") | keys | .[] | select(test("(?i)^secrets$"))] | length' "$wf")" != "0" ]; then
    printf 'a job passes secrets: on\n'
  fi

  for job in prepare publish; do
    perms="$(yq -o=json -I=0 ".jobs.${job}.permissions // null" "$wf")"
    if [ "$perms" != '{"contents":"read"}' ]; then
      printf '%s: permissions are not exactly contents: read: %s\n' "$job" "$perms"
    fi
    if [ "$(yq -r ".jobs.${job}.env // {} | has(\"VRG_AUTOMATION_APP\")" "$wf")" = "true" ]; then
      printf '%s: job env sets VRG_AUTOMATION_APP\n' "$job"
    fi
    check_guard "$wf" "$job"
    persist="$(yq -r ".jobs.${job}.steps[] | select((.uses // \"\") | test(\"^actions/checkout@\"))
      | (.with // {}) | .\"persist-credentials\" | to_string" "$wf")"
    if [ -z "$persist" ]; then
      printf '%s: has no checkout step\n' "$job"
    elif [ "$persist" != "false" ]; then
      printf '%s: a checkout does not set persist-credentials: false: %s\n' "$job" "$persist"
    fi
  done
  if [ "$(yq -r '(.env // {}) | has("VRG_AUTOMATION_APP")' "$wf")" = "true" ]; then
    printf 'workflow env sets VRG_AUTOMATION_APP\n'
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf 'prepare sets %s\n' "$path"
  done < <(yq -r '.jobs.prepare | .. | select(tag == "!!map") | to_entries | .[]
    | select(.key | test("^VRG_AUTOMATION_")) | .key' "$wf")

  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$(yq -r '[.jobs.prepare.steps[] | select((.run // "") | test("vrg-upstream-refresh prepare"))
    | (.env // {}).GH_TOKEN // ""] | join(",")' "$wf")" != '${{ github.token }}' ]; then
    printf 'prepare has no single tool step with GH_TOKEN from ${{ github.token }}\n'
  fi

  # shellcheck disable=SC2016 # $j in the yq query below is a yq variable
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s has an if:\n' "$path"
  done < <(yq -r '(.jobs | to_entries | .[] | select(.value | has("if")) | "jobs." + .key),
    (.jobs | to_entries | .[] | .key as $j | (.value.steps // []) | to_entries | .[]
      | select(.value | has("if")) | "jobs." + $j + ".steps." + (.key | to_string))' "$wf")

  timeout="$(yq -r '.jobs.prepare."timeout-minutes" // "unset"' "$wf")"
  [ "$timeout" = "30" ] || printf 'prepare: timeout-minutes is not 30: %s\n' "$timeout"
  timeout="$(yq -r '.jobs.publish."timeout-minutes" // "unset"' "$wf")"
  [ "$timeout" = "140" ] || printf 'publish: timeout-minutes is not 140: %s\n' "$timeout"

  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$(yq -o=json -I=0 '.concurrency // null' "$wf")" != '{"group":"${{ github.repository }}/upstream-refresh","cancel-in-progress":false}' ]; then
    printf 'the workflow concurrency is not ${{ github.repository }}/upstream-refresh, never cancelled\n'
  fi

  if [ "$(yq -r '[.. | select(tag == "!!str" and test("create-github-app-token"))] | length' "$wf")" != "0" ]; then
    printf 'create-github-app-token is used\n'
  fi
  if [ "$(yq -r '[.. | select(tag == "!!str" and test("gh auth setup-git"))] | length' "$wf")" != "0" ]; then
    printf 'gh auth setup-git is run\n'
  fi
}

# expect_clean <case> <workflow file>
expect_clean() {
  local out
  out="$(violations "$2")"
  if [ -n "$out" ]; then
    fail_case "$1" "$out"
    return 0
  fi
  pass_case "$1"
}

# expect_caught <case> <yq edit> <substring of the expected violation> —
# apply the edit to a copy of the real workflow and expect the violation.
expect_caught() {
  local wf="${tmp}/$1.yml" out
  cp "$real" "$wf"
  if ! out="$(yq -i "$2" "$wf" 2>&1)"; then
    fail_case "$1" "the fixture edit does not apply to the workflow: ${out}"
    return 0
  fi
  out="$(violations "$wf")"
  case "$out" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$3', got: ${out:-<none>}" ;;
  esac
}

case_real_workflow() {
  expect_clean "ops-upstream-refresh-keeps-the-key-boundary" "$real"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  expect_caught "fixture-key-on-prepare-caught" \
    '.jobs.prepare.steps[-1].env.KEY = "${{ secrets.APP_PRIVATE_KEY }}"' \
    "secrets referenced outside the publish step env: jobs.prepare.steps"
  expect_caught "fixture-key-on-publish-job-env-caught" \
    '.jobs.publish.env.VRG_AUTOMATION_PRIVATE_KEY = "${{ secrets.APP_PRIVATE_KEY }}"' \
    "secrets referenced outside the publish step env: jobs.publish.env.VRG_AUTOMATION_PRIVATE_KEY"
  expect_caught "fixture-client-id-on-install-step-caught" \
    '(.jobs.publish.steps[] | select(.uses == "./actions/shared/setup/vergil")).env.X = "${{ secrets.APP_CLIENT_ID }}"' \
    "secrets referenced outside the publish step env: jobs.publish.steps"
  expect_caught "fixture-workflow-env-secret-caught" \
    '.env.K = "${{ toJSON(secrets) }}"' \
    "secrets referenced outside the publish step env: env.K"
  expect_caught "fixture-swapped-credentials-caught" \
    '(.jobs.publish.steps[] | select((.run // "") | test("vrg-upstream-refresh publish"))).env.VRG_AUTOMATION_CLIENT_ID = "${{ secrets.APP_PRIVATE_KEY }}"' \
    "VRG_AUTOMATION_CLIENT_ID is not \${{ secrets.APP_CLIENT_ID }}"
  expect_caught "fixture-publish-step-without-key-caught" \
    'del((.jobs.publish.steps[] | select((.run // "") | test("vrg-upstream-refresh publish"))).env.VRG_AUTOMATION_PRIVATE_KEY)' \
    "the publish step does not set VRG_AUTOMATION_PRIVATE_KEY"
  expect_caught "fixture-prepare-write-permission-caught" \
    '.jobs.prepare.permissions.contents = "write"' \
    "prepare: permissions are not exactly contents: read"
  expect_caught "fixture-prepare-automation-app-caught" \
    '.jobs.prepare.steps[-1].env.VRG_AUTOMATION_APP = "${{ vars.VRG_AUTOMATION_APP }}"' \
    "prepare sets VRG_AUTOMATION_APP"
  expect_caught "fixture-job-env-automation-app-caught" \
    '.jobs.publish.env.VRG_AUTOMATION_APP = "${{ vars.VRG_AUTOMATION_APP }}"' \
    "publish: job env sets VRG_AUTOMATION_APP"
  expect_caught "fixture-workflow-env-automation-app-caught" \
    '.env.VRG_AUTOMATION_APP = "${{ vars.VRG_AUTOMATION_APP }}"' \
    "workflow env sets VRG_AUTOMATION_APP"
  expect_caught "fixture-publish-guard-missing-caught" \
    'del(.jobs.publish.steps[0])' \
    "publish: the first step is not the develop guard"
  expect_caught "fixture-prepare-guard-without-variable-caught" \
    'del(.jobs.prepare.steps[0].env.AUTOMATION_APP)' \
    "prepare: the first step is not the develop guard"
  expect_caught "fixture-step-if-caught" \
    '.jobs.publish.steps[-1].if = "success()"' \
    "jobs.publish.steps."
  expect_caught "fixture-job-if-caught" \
    '.jobs.prepare.if = "always()"' \
    "jobs.prepare has an if:"
  expect_caught "fixture-prepare-timeout-caught" \
    'del(.jobs.prepare."timeout-minutes")' \
    "prepare: timeout-minutes is not 30: unset"
  expect_caught "fixture-publish-timeout-caught" \
    '.jobs.publish."timeout-minutes" = 360' \
    "publish: timeout-minutes is not 140: 360"
  expect_caught "fixture-persisted-credentials-caught" \
    'del((.jobs.publish.steps[] | select(.uses == "actions/checkout@v6")).with."persist-credentials")' \
    "publish: a checkout does not set persist-credentials: false"
  expect_caught "fixture-prepare-write-token-caught" \
    '(.jobs.prepare.steps[] | select((.run // "") | test("vrg-upstream-refresh prepare"))).env.GH_TOKEN = "${{ steps.app-token.outputs.token }}"' \
    "prepare has no single tool step with GH_TOKEN"
  expect_caught "fixture-no-needs-caught" \
    'del(.jobs.publish.needs)' \
    "publish does not need prepare"
  expect_caught "fixture-third-job-caught" \
    '.jobs.extra = {"runs-on": "ubuntu-24.04"}' \
    "the jobs are not exactly prepare and publish"
  expect_caught "fixture-cancelled-concurrency-caught" \
    '.concurrency."cancel-in-progress" = true' \
    "the workflow concurrency is not"
  expect_caught "fixture-app-token-action-caught" \
    '.jobs.publish.steps += [{"id": "app-token", "uses": "actions/create-github-app-token@v3"}]' \
    "create-github-app-token is used"
  expect_caught "fixture-setup-git-caught" \
    '.jobs.publish.steps += [{"run": "gh auth setup-git"}]' \
    "gh auth setup-git is run"
}

case_real_workflow
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
