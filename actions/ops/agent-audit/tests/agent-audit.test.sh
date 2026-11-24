#!/usr/bin/env bash
#
# Test the layout of ops-agent-audit.yml (vergil-project/vergil-actions#1341,
# epic vergil-project/.github#1384, plan Task 13).
#
# The daily audit of agent merges runs `vrg-agent-audit --repo <calling repo>`
# as the org automation App, whose token can move the audit markers
# (vergil/agent-audit/develop and vergil/agent-audit/main). A wiring mistake
# that widened that token, ran it from another branch, gave the audit a
# shallow clone or reported its findings to a public ops issue would not fail
# any run, so this test is the guard.
#
# Framework-free and developer-runnable: `bash agent-audit.test.sh`. CI runs
# it from .github/workflows/smoke-setup-vergil.yml and validation runs it
# with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, checked on ops-agent-audit.yml:
#   * workflow_call takes APP_CLIENT_ID and APP_PRIVATE_KEY, each
#     `required: true`, and the workflow-level permissions are exactly
#     contents: read;
#   * the one job is agent-audit, named agent-audit (the name hoshin reads
#     it by), in the automation environment, with timeout-minutes 60 and the
#     concurrency group `${{ github.repository }}/agent-audit`, never
#     cancelled, and no `if:`;
#   * its first step is the develop guard: it reads github.ref as REF and
#     fails unless REF is refs/heads/develop;
#   * one create-github-app-token step, before the checkout, scoped to the
#     calling repository (no owner or repositories input), asks for exactly
#     contents write, pull-requests read, issues read and metadata read;
#   * secrets.APP_CLIENT_ID and secrets.APP_PRIVATE_KEY appear only as that
#     step's app-id and private-key inputs; no other value names secrets;
#   * the checkout is of develop with fetch-depth 0 and no repository input,
#     so the clone has full history and its origin is the calling repository;
#   * exactly one step runs vrg-agent-audit, as `vrg-agent-audit --repo
#     "$REPO"` with REPO from github.repository, GH_TOKEN from the token
#     step and VRG_TRUSTED_AUTHORS from the org variable, and no value runs
#     `--init`;
#   * it is a security signal: no step uses the ops-report action and no
#     job runs only to report.
# Fixture copies of the workflow, each broken one way, check that each rule
# catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
real="${repo_root}/.github/workflows/ops-agent-audit.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'agent-audit.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$real" ]; then
  printf 'agent-audit.test.sh: missing %s\n' "$real" >&2
  exit 1
fi

expected_permissions='permission-contents=write
permission-issues=read
permission-metadata=read
permission-pull-requests=read'

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

# violations <workflow file> — print one line per rule the workflow breaks,
# nothing when it keeps them all.
violations() {
  local wf="$1" job='.jobs."agent-audit"' jobs value secret first ref run uses
  local token_idx token_count checkout_idx checkout_count audit_idx audit_count
  local path expected permissions

  for secret in APP_CLIENT_ID APP_PRIVATE_KEY; do
    value="$(yq -r ".on.workflow_call.secrets.${secret}.required // \"<unset>\" | to_string" "$wf")"
    if [ "$value" != "true" ]; then
      printf 'workflow_call secret %s is not required: true: %s\n' "$secret" "$value"
    fi
  done
  value="$(yq -o=json -I=0 '.permissions // null' "$wf")"
  if [ "$value" != '{"contents":"read"}' ]; then
    printf 'the workflow permissions are not exactly contents: read: %s\n' "$value"
  fi

  jobs="$(yq -r '(.jobs // {}) | keys | join(",")' "$wf")"
  if [ "$jobs" != "agent-audit" ]; then
    printf 'the jobs are not exactly agent-audit: %s\n' "${jobs:-<none>}"
    return 0
  fi
  value="$(yq -r "${job}.name // \"<unset>\"" "$wf")"
  [ "$value" = "agent-audit" ] || printf 'the job name is not agent-audit: %s\n' "$value"
  value="$(yq -r "${job}.environment // \"<unset>\" | to_string" "$wf")"
  [ "$value" = "automation" ] || printf 'the job environment is not automation: %s\n' "$value"
  value="$(yq -r "${job}.\"timeout-minutes\" // \"<unset>\" | to_string" "$wf")"
  [ "$value" = "60" ] || printf 'the job timeout-minutes is not 60: %s\n' "$value"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$(yq -o=json -I=0 "${job}.concurrency // null" "$wf")" != '{"group":"${{ github.repository }}/agent-audit","cancel-in-progress":false}' ]; then
    printf 'the job concurrency is not ${{ github.repository }}/agent-audit, never cancelled\n'
  fi
  if [ "$(yq -r "${job} | has(\"if\")" "$wf")" = "true" ]; then
    printf 'the job has an if:\n'
  fi

  # The develop guard, before any token is minted.
  first="${job}.steps[0]"
  ref="$(yq -r "${first}.env.REF // \"\"" "$wf")"
  run="$(yq -r "${first}.run // \"\"" "$wf")"
  uses="$(yq -r "${first}.uses // \"\"" "$wf")"
  # shellcheck disable=SC2016 # literal GitHub Actions expressions and shell tests
  if [ -n "$uses" ] ||
    [ "$ref" != '${{ github.ref }}' ] ||
    [[ "$run" != *'[ "${REF}" != "refs/heads/develop" ]'* ]] ||
    [[ "$run" != *'exit 1'* ]]; then
    printf 'the first step is not the develop guard\n'
  fi

  token_count="$(yq -r "[${job}.steps[] | select((.uses // \"\") | test(\"^actions/create-github-app-token@\"))] | length" "$wf")"
  token_idx="$(yq -r "[${job}.steps | to_entries | .[]
    | select((.value.uses // \"\") | test(\"^actions/create-github-app-token@\")) | .key] | .[0] // \"\"" "$wf")"
  checkout_count="$(yq -r "[${job}.steps[] | select((.uses // \"\") | test(\"^actions/checkout@\"))] | length" "$wf")"
  checkout_idx="$(yq -r "[${job}.steps | to_entries | .[]
    | select((.value.uses // \"\") | test(\"^actions/checkout@\")) | .key] | .[0] // \"\"" "$wf")"
  if [ "$token_count" != "1" ]; then
    printf 'the job has %s create-github-app-token steps, not 1\n' "$token_count"
  fi
  if [ "$checkout_count" != "1" ]; then
    printf 'the job has %s checkout steps, not 1\n' "$checkout_count"
  fi

  if [ "$token_count" = "1" ]; then
    if [ "$checkout_count" = "1" ] && [ "$token_idx" -gt "$checkout_idx" ]; then
      printf 'the token is minted after the checkout\n'
    fi
    for value in owner repositories; do
      if [ "$(yq -r "${job}.steps[${token_idx}].with // {} | has(\"${value}\")" "$wf")" = "true" ]; then
        printf 'the token step sets %s: the token is not scoped to the calling repository\n' "$value"
      fi
    done
    permissions="$(yq -r "${job}.steps[${token_idx}].with // {} | to_entries | .[]
      | select(.key | test(\"^permission-\")) | .key + \"=\" + (.value | to_string)" "$wf" | sort)"
    if [ "$permissions" != "$expected_permissions" ]; then
      printf 'the token permissions are not exactly contents write, issues, metadata and pull-requests read: %s\n' \
        "$(paste -sd, - <<<"$permissions")"
    fi
  fi

  # Every string value that names secrets, wherever it is (comments are not
  # values). Context names are case-insensitive, so the match is too. The
  # workflow_call secret declarations are keys, not values.
  while IFS=$'\t' read -r path value; do
    [ -n "$path" ] || continue
    case "$path" in
      "jobs.agent-audit.steps.${token_idx:-x}.with.app-id")
        # shellcheck disable=SC2016 # a literal GitHub Actions expression
        expected='${{ secrets.APP_CLIENT_ID }}'
        ;;
      "jobs.agent-audit.steps.${token_idx:-x}.with.private-key")
        # shellcheck disable=SC2016 # a literal GitHub Actions expression
        expected='${{ secrets.APP_PRIVATE_KEY }}'
        ;;
      *)
        printf 'secrets referenced outside the token step inputs: %s: %s\n' "$path" "$value"
        continue
        ;;
    esac
    if [ "$value" != "$expected" ]; then
      printf '%s is not %s: %s\n' "$path" "$expected" "$value"
    fi
  done < <(yq -r '.. | select(tag == "!!str" and test("(?i)(^|[^A-Za-z0-9_])secrets([^A-Za-z0-9_]|$)"))
    | [(path | join(".")), .] | @tsv' "$wf")

  if [ "$checkout_count" = "1" ]; then
    value="$(yq -r "${job}.steps[${checkout_idx}].with.\"fetch-depth\" // \"<unset>\" | to_string" "$wf")"
    [ "$value" = "0" ] || printf 'the checkout fetch-depth is not 0: %s\n' "$value"
    value="$(yq -r "${job}.steps[${checkout_idx}].with.ref // \"<unset>\"" "$wf")"
    [ "$value" = "develop" ] || printf 'the checkout ref is not develop: %s\n' "$value"
    if [ "$(yq -r "${job}.steps[${checkout_idx}].with // {} | has(\"repository\")" "$wf")" = "true" ]; then
      printf 'the checkout names a repository: origin must be the calling repository\n'
    fi
  fi

  audit_count="$(yq -r "[${job}.steps[] | select((.run // \"\") | test(\"vrg-agent-audit\"))] | length" "$wf")"
  audit_idx="$(yq -r "[${job}.steps | to_entries | .[]
    | select((.value.run // \"\") | test(\"vrg-agent-audit\")) | .key] | .[0] // \"\"" "$wf")"
  if [ "$audit_count" != "1" ]; then
    printf 'the job has %s steps running vrg-agent-audit, not 1\n' "$audit_count"
  else
    value="$(yq -r "${job}.steps[${audit_idx}].run" "$wf")"
    # shellcheck disable=SC2016 # a literal shell command
    [ "$value" = 'vrg-agent-audit --repo "$REPO"' ] ||
      printf 'the audit step does not run exactly vrg-agent-audit --repo "$REPO": %s\n' "$value"
    # shellcheck disable=SC2016 # literal GitHub Actions expressions
    for value in 'REPO=${{ github.repository }}' \
      'GH_TOKEN=${{ steps.app-token.outputs.token }}' \
      'VRG_TRUSTED_AUTHORS=${{ vars.VRG_TRUSTED_AUTHORS }}'; do
      if [ "$(N="${value%%=*}" yq -r "${job}.steps[${audit_idx}].env[strenv(N)] // \"<unset>\"" "$wf")" != "${value#*=}" ]; then
        printf 'the audit step %s is not %s\n' "${value%%=*}" "${value#*=}"
      fi
    done
    if [ "$token_count" = "1" ] && [ "$(yq -r "${job}.steps[${token_idx}].id // \"\"" "$wf")" != "app-token" ]; then
      printf 'the token step id is not app-token\n'
    fi
  fi
  if [ "$(yq -r '[.. | select(tag == "!!str" and test("--init"))] | length' "$wf")" != "0" ]; then
    printf 'a value runs --init: a scheduled audit never creates a marker\n'
  fi

  if [ "$(yq -r '[.. | select(tag == "!!str" and test("actions/ops/report"))] | length' "$wf")" != "0" ]; then
    printf 'the security-signal audit is reported through ops-report\n'
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
  expect_clean "ops-agent-audit-keeps-its-layout" "$real"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  local audit='(.jobs."agent-audit".steps[] | select((.run // "") | test("vrg-agent-audit")))'
  local token='(.jobs."agent-audit".steps[] | select((.uses // "") | test("^actions/create-github-app-token@")))'
  local checkout='(.jobs."agent-audit".steps[] | select((.uses // "") | test("^actions/checkout@")))'

  expect_caught "fixture-optional-key-caught" \
    '.on.workflow_call.secrets.APP_PRIVATE_KEY.required = false' \
    "workflow_call secret APP_PRIVATE_KEY is not required: true"
  expect_caught "fixture-workflow-write-permission-caught" \
    '.permissions.contents = "write"' \
    "the workflow permissions are not exactly contents: read"
  expect_caught "fixture-extra-job-caught" \
    '.jobs.report = .jobs."agent-audit"' \
    "the jobs are not exactly agent-audit"
  expect_caught "fixture-job-renamed-caught" \
    '.jobs."agent-audit".name = "audit"' \
    "the job name is not agent-audit"
  expect_caught "fixture-no-environment-caught" \
    'del(.jobs."agent-audit".environment)' \
    "the job environment is not automation"
  expect_caught "fixture-timeout-caught" \
    '.jobs."agent-audit"."timeout-minutes" = 360' \
    "the job timeout-minutes is not 60"
  expect_caught "fixture-cancelled-concurrency-caught" \
    '.jobs."agent-audit".concurrency."cancel-in-progress" = true' \
    "the job concurrency is not"
  expect_caught "fixture-job-if-caught" \
    '.jobs."agent-audit".if = "github.event_name == '"'"'schedule'"'"'"' \
    "the job has an if:"
  expect_caught "fixture-guard-missing-caught" \
    'del(.jobs."agent-audit".steps[0])' \
    "the first step is not the develop guard"
  expect_caught "fixture-guard-other-ref-caught" \
    '.jobs."agent-audit".steps[0].run |= sub("refs/heads/develop", "refs/heads/main")' \
    "the first step is not the develop guard"
  expect_caught "fixture-token-after-checkout-caught" \
    '.jobs."agent-audit".steps |= ([.[0], .[2], .[1]] + .[3:])' \
    "the token is minted after the checkout"
  expect_caught "fixture-org-wide-token-caught" \
    "${token}"'.with.owner = "${{ github.repository_owner }}"' \
    "the token step sets owner"
  expect_caught "fixture-extra-permission-caught" \
    "${token}"'.with."permission-administration" = "write"' \
    "the token permissions are not exactly"
  expect_caught "fixture-issues-write-caught" \
    "${token}"'.with."permission-issues" = "write"' \
    "the token permissions are not exactly"
  expect_caught "fixture-second-token-caught" \
    '.jobs."agent-audit".steps += [.jobs."agent-audit".steps[1]]' \
    "the job has 2 create-github-app-token steps, not 1"
  expect_caught "fixture-key-on-audit-step-caught" \
    "${audit}"'.env.KEY = "${{ secrets.APP_PRIVATE_KEY }}"' \
    "secrets referenced outside the token step inputs: jobs.agent-audit.steps"
  expect_caught "fixture-dynamic-secrets-caught" \
    '.jobs."agent-audit".env.ALL = "${{ toJSON(secrets) }}"' \
    "secrets referenced outside the token step inputs: jobs.agent-audit.env.ALL"
  expect_caught "fixture-swapped-key-caught" \
    "${token}"'.with.app-id = "${{ secrets.APP_PRIVATE_KEY }}"' \
    "app-id is not \${{ secrets.APP_CLIENT_ID }}"
  expect_caught "fixture-shallow-clone-caught" \
    'del('"${checkout}"'.with."fetch-depth")' \
    "the checkout fetch-depth is not 0"
  expect_caught "fixture-checkout-other-ref-caught" \
    "${checkout}"'.with.ref = "${{ github.ref }}"' \
    "the checkout ref is not develop"
  expect_caught "fixture-checkout-other-repo-caught" \
    "${checkout}"'.with.repository = "vergil-project/vergil-actions"' \
    "the checkout names a repository"
  expect_caught "fixture-no-audit-step-caught" \
    'del('"${audit}"')' \
    "the job has 0 steps running vrg-agent-audit, not 1"
  expect_caught "fixture-audit-inline-repo-caught" \
    "${audit}"'.run = "vrg-agent-audit --repo \"${{ github.repository }}\""' \
    "the audit step does not run exactly"
  expect_caught "fixture-audit-init-caught" \
    "${audit}"'.run = "vrg-agent-audit --repo \"$REPO\" --init"' \
    "a value runs --init"
  expect_caught "fixture-audit-github-token-caught" \
    "${audit}"'.env.GH_TOKEN = "${{ github.token }}"' \
    "the audit step GH_TOKEN is not"
  expect_caught "fixture-audit-no-trusted-authors-caught" \
    'del('"${audit}"'.env.VRG_TRUSTED_AUTHORS)' \
    "the audit step VRG_TRUSTED_AUTHORS is not"
  expect_caught "fixture-reported-caught" \
    '.jobs."agent-audit".steps += [{"name": "Report", "uses": "./actions/ops/report"}]' \
    "the security-signal audit is reported through ops-report"
}

case_real_workflow
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
