#!/usr/bin/env bash
#
# Test the ops-report action's ref guard (issue #1361, epic
# vergil-project/.github#1494, plan Review Focus item 5).
#
# A feature-branch `workflow_dispatch` of a reporting workflow must mint no
# App token and file nothing: the action reports only from refs/heads/develop
# (spec §5.3). The guard is the action's first step; every later step, the
# token step included, runs only when the guard says `report=true`.
#
# Framework-free and developer-runnable: `bash ops-report-ref-guard.test.sh`.
# CI runs it from .github/workflows/smoke-ops-report.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, checked on actions/ops/report/action.yml:
#   * step 0 has id `ref-guard`, reads `${{ github.ref }}` as REF in its env,
#     compares it with refs/heads/develop, and writes `report=false` (and
#     exits 0) on any other ref and `report=true` on develop;
#   * the token step (actions/create-github-app-token) comes after it;
#   * every step after it has an `if:` of exactly
#     `steps.ref-guard.outputs.report == 'true'`.
# Fixture actions check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action="${here}/../action.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'ops-report-ref-guard.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$action" ]; then
  printf 'ops-report-ref-guard.test.sh: missing %s\n' "$action" >&2
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

guard_if="steps.ref-guard.outputs.report == 'true'"

# violations <action file> — print one line per rule the action breaks,
# nothing when it keeps them all.
violations() {
  local file="$1" count id ref run token_idx idx cond
  count="$(yq -r '(.runs.steps // []) | length' "$file")"
  if [ "$count" -eq 0 ]; then
    printf 'the action has no steps\n'
    return 0
  fi
  id="$(yq -r '.runs.steps[0].id // "<unset>"' "$file")"
  if [ "$id" != "ref-guard" ]; then
    printf 'step 0 is not the ref guard (id %s)\n' "$id"
  fi
  ref="$(yq -r '(.runs.steps[0].env // {}).REF // "<unset>"' "$file")"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$ref" != '${{ github.ref }}' ]; then
    printf 'step 0 does not read ${{ github.ref }} as REF: %s\n' "$ref"
  fi
  run="$(yq -r '.runs.steps[0].run // ""' "$file")"
  # shellcheck disable=SC2016 # the literal shell test the step must contain
  case "$run" in
    *'[ "${REF}" != "refs/heads/develop" ]'*) ;;
    *) printf 'step 0 does not compare REF with refs/heads/develop\n' ;;
  esac
  case "$run" in
    *'echo "report=false" >>"${GITHUB_OUTPUT}"'*) ;;
    *) printf 'step 0 does not write report=false\n' ;;
  esac
  case "$run" in
    *'echo "report=true"'*) ;;
    *) printf 'step 0 does not write report=true\n' ;;
  esac
  token_idx="$(yq -r '.runs.steps | to_entries | .[]
    | select((.value.uses // "") | test("^actions/create-github-app-token@")) | .key' "$file")"
  if [ -z "$token_idx" ]; then
    printf 'the action has no token step\n'
  elif [ "$token_idx" -lt 1 ]; then
    printf 'the token step (step %s) does not follow the ref guard\n' "$token_idx"
  fi
  idx=1
  while [ "$idx" -lt "$count" ]; do
    cond="$(yq -r ".runs.steps[${idx}].if // \"<unset>\"" "$file")"
    if [ "$cond" != "$guard_if" ]; then
      printf 'step %s is not conditioned on the ref guard: %s\n' "$idx" "$cond"
    fi
    idx=$((idx + 1))
  done
}

# expect_clean <case> <action file>
expect_clean() {
  local out
  out="$(violations "$2")"
  if [ -n "$out" ]; then
    fail_case "$1" "$out"
    return 0
  fi
  pass_case "$1"
}

# expect_caught <case> <action file> <substring of the expected violation>
expect_caught() {
  local out
  out="$(violations "$2")"
  case "$out" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$3', got: ${out:-<none>}" ;;
  esac
}

# write_guard <file> — the start of a fixture action: a clean ref guard.
write_guard() {
  cat >"$1" <<'YAML'
runs:
  using: composite
  steps:
    - id: ref-guard
      shell: bash
      env:
        REF: ${{ github.ref }}
      run: |
        if [ "${REF}" != "refs/heads/develop" ]; then
          echo "report=false" >>"${GITHUB_OUTPUT}"
          exit 0
        fi
        echo "report=true" >>"${GITHUB_OUTPUT}"
YAML
}

case_real_action() {
  expect_clean "ops-report-ref-guard-first-and-gates-every-step" "$action"
}

# Run the guard's own shell against both refs: develop reports, any other
# ref writes report=false and exits 0, with no token.
case_guard_behaviour() {
  local run out rc
  run="$(yq -r '.runs.steps[0].run' "$action")"
  out="${tmp}/out-feature"
  : >"$out"
  rc=0
  REF=refs/heads/feature/x REPO=o/r GITHUB_OUTPUT="$out" bash -c "$run" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && grep -qx 'report=false' "$out" && ! grep -q 'report=true' "$out"; then
    pass_case "guard-feature-branch-reports-nothing"
  else
    fail_case "guard-feature-branch-reports-nothing" "exit ${rc}, output: $(cat "$out")"
  fi

  out="${tmp}/out-develop"
  : >"$out"
  rc=0
  REF=refs/heads/develop REPO=o/r VRG_AUTOMATION_APP=o-automation \
    VRG_TRUSTED_AUTHORS='{}' GITHUB_OUTPUT="$out" bash -c "$run" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && grep -qx 'report=true' "$out" && grep -qx 'repositories=r,.github' "$out"; then
    pass_case "guard-develop-reports"
  else
    fail_case "guard-develop-reports" "exit ${rc}, output: $(cat "$out")"
  fi

  out="${tmp}/out-dotgithub"
  : >"$out"
  rc=0
  REF=refs/heads/develop REPO=o/.github VRG_AUTOMATION_APP=o-automation \
    VRG_TRUSTED_AUTHORS='{}' GITHUB_OUTPUT="$out" bash -c "$run" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && grep -qx 'repositories=.github' "$out"; then
    pass_case "guard-dotgithub-repo-named-once"
  else
    fail_case "guard-dotgithub-repo-named-once" "exit ${rc}, output: $(cat "$out")"
  fi

  out="${tmp}/out-no-app"
  : >"$out"
  rc=0
  env -u VRG_AUTOMATION_APP REF=refs/heads/develop REPO=o/r VRG_TRUSTED_AUTHORS='{}' \
    GITHUB_OUTPUT="$out" bash -c "$run" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q 'report=true' "$out"; then
    pass_case "guard-develop-without-automation-app-fails"
  else
    fail_case "guard-develop-without-automation-app-fails" "exit ${rc}, output: $(cat "$out")"
  fi

  out="${tmp}/out-no-authors"
  : >"$out"
  rc=0
  env -u VRG_TRUSTED_AUTHORS REF=refs/heads/develop REPO=o/r VRG_AUTOMATION_APP=o-automation \
    GITHUB_OUTPUT="$out" bash -c "$run" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q 'report=true' "$out"; then
    pass_case "guard-develop-without-trusted-authors-fails"
  else
    fail_case "guard-develop-without-trusted-authors-fails" "exit ${rc}, output: $(cat "$out")"
  fi
}

case_fixtures() {
  write_guard "${tmp}/good.yml"
  cat >>"${tmp}/good.yml" <<'YAML'
    - id: app-token
      if: steps.ref-guard.outputs.report == 'true'
      uses: actions/create-github-app-token@v3
    - if: steps.ref-guard.outputs.report == 'true'
      shell: bash
      run: vrg-ops-report
YAML
  expect_clean "fixture-guarded-is-clean" "${tmp}/good.yml"

  cat >"${tmp}/token-first.yml" <<'YAML'
runs:
  using: composite
  steps:
    - id: app-token
      uses: actions/create-github-app-token@v3
    - id: ref-guard
      shell: bash
      env:
        REF: ${{ github.ref }}
      run: |
        if [ "${REF}" != "refs/heads/develop" ]; then
          echo "report=false" >>"${GITHUB_OUTPUT}"
          exit 0
        fi
        echo "report=true" >>"${GITHUB_OUTPUT}"
YAML
  expect_caught "fixture-token-before-guard-caught" "${tmp}/token-first.yml" \
    "the token step (step 0) does not follow the ref guard"

  write_guard "${tmp}/unguarded-token.yml"
  cat >>"${tmp}/unguarded-token.yml" <<'YAML'
    - id: app-token
      uses: actions/create-github-app-token@v3
YAML
  expect_caught "fixture-unguarded-token-caught" "${tmp}/unguarded-token.yml" \
    "step 1 is not conditioned on the ref guard: <unset>"

  write_guard "${tmp}/unguarded-report.yml"
  cat >>"${tmp}/unguarded-report.yml" <<'YAML'
    - id: app-token
      if: steps.ref-guard.outputs.report == 'true'
      uses: actions/create-github-app-token@v3
    - if: always()
      shell: bash
      run: vrg-ops-report
YAML
  expect_caught "fixture-report-step-not-guarded-caught" "${tmp}/unguarded-report.yml" \
    "step 2 is not conditioned on the ref guard: always()"

  cat >"${tmp}/wrong-ref.yml" <<'YAML'
runs:
  using: composite
  steps:
    - id: ref-guard
      shell: bash
      env:
        REF: ${{ github.head_ref }}
      run: echo "report=true" >>"${GITHUB_OUTPUT}"
    - id: app-token
      if: steps.ref-guard.outputs.report == 'true'
      uses: actions/create-github-app-token@v3
YAML
  expect_caught "fixture-guard-not-reading-github-ref-caught" "${tmp}/wrong-ref.yml" \
    "step 0 does not read \${{ github.ref }} as REF"
  expect_caught "fixture-guard-not-comparing-develop-caught" "${tmp}/wrong-ref.yml" \
    "step 0 does not compare REF with refs/heads/develop"

  cat >"${tmp}/no-token.yml" <<'YAML'
runs:
  using: composite
  steps:
    - id: ref-guard
      shell: bash
      run: true
YAML
  expect_caught "fixture-no-token-step-caught" "${tmp}/no-token.yml" \
    "the action has no token step"
}

case_real_action
case_guard_behaviour
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
