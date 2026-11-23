#!/usr/bin/env bash
#
# Test that a docs refresh run is reported once, as docs-refresh (issue
# #1362, epic vergil-project/.github#1494, spec §5.3).
#
# cd-docs-refresh.yml is a thin wrapper over cd-docs.yml, and both now end
# with a reporting job. Left alone, a refresh run would be reported twice:
# as docs-refresh by the wrapper and as docs-deploy-develop by the nested
# cd-docs.yml. So cd-docs.yml's reporting job runs only when its `report`
# input is true, and the wrapper's nested call passes `report: false` and
# forwards both App secrets.
#
# Framework-free and developer-runnable: `bash docs-refresh-reports-once.test.sh`.
# CI runs it from .github/workflows/smoke-ops-report.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules:
#   * cd-docs.yml's `report` job's `if:` has `inputs.report` as a top-level
#     `&&` condition (inside an `||` or a parenthesis it would not turn the
#     job off on its own);
#   * cd-docs-refresh.yml has its own reporting job for docs-refresh, and
#     its call of cd-docs.yml passes `report: false` and each App secret
#     from the secret of the same name.
# Fixture copies of the workflows check that each rule catches its
# violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"
docs="${workflows}/cd-docs.yml"
refresh="${workflows}/cd-docs-refresh.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'docs-refresh-reports-once.test.sh needs yq on PATH\n' >&2
  exit 1
fi
for f in "$docs" "$refresh"; do
  if [ ! -f "$f" ]; then
    printf 'docs-refresh-reports-once.test.sh: missing %s\n' "$f" >&2
    exit 1
  fi
done

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

# shellcheck source=actions/ops/report/tests/conjuncts.sh
. "${here}/conjuncts.sh"

# docs_violations <cd-docs.yml> — the reporting job is gated on the input.
docs_violations() {
  local cond
  cond="$(yq -r '.jobs.report.if // ""' "$1")"
  if ! grep -qxF -- "inputs.report" <<<"$(conjuncts "$cond")"; then
    printf 'cd-docs.yml report: the if: has no top-level inputs.report: %s\n' "${cond:-<unset>}"
  fi
}

# refresh_violations <cd-docs-refresh.yml> — the wrapper reports as
# docs-refresh and turns the nested report off.
refresh_violations() {
  local wf="$1" jobs job value name
  if [ "$(yq -r '[(.jobs // {}) | .[] | (.steps // [])[]
    | select((.uses // "") == "./actions/ops/report" and .with.job == "docs-refresh")] | length' "$wf")" != "1" ]; then
    printf 'cd-docs-refresh.yml: has no single ops-report step for docs-refresh\n'
  fi
  jobs="$(yq -r '(.jobs // {}) | to_entries | .[]
    | select((.value.uses // "") | test("/cd-docs\.yml@")) | .key' "$wf")"
  if [ -z "$jobs" ]; then
    printf 'cd-docs-refresh.yml: has no job calling cd-docs.yml\n'
    return 0
  fi
  while IFS= read -r job; do
    value="$(yq -r ".jobs.\"${job}\".with.report" "$wf")"
    if [ "$value" != "false" ]; then
      printf 'cd-docs-refresh.yml %s: does not pass report: false (%s)\n' "$job" "$value"
    fi
    for name in APP_CLIENT_ID APP_PRIVATE_KEY; do
      value="$(yq -r ".jobs.\"${job}\".secrets | select(tag == \"!!map\") | .${name} // \"<unset>\"" "$wf")"
      # No map at all (no secrets, or secrets: inherit) prints nothing.
      value="${value:-<unset>}"
      if [ "$value" != "\${{ secrets.${name} }}" ]; then
        printf 'cd-docs-refresh.yml %s: does not forward %s: %s\n' "$job" "$name" "$value"
      fi
    done
  done <<<"$jobs"
}

# expect_caught <case> <cd-docs.yml|cd-docs-refresh.yml> <yq edit>
# <substring of the expected violation>
expect_caught() {
  local d="${tmp}/$1-docs.yml" r="${tmp}/$1-refresh.yml" target out
  cp "$docs" "$d"
  cp "$refresh" "$r"
  case "$2" in
    cd-docs.yml) target="$d" ;;
    *) target="$r" ;;
  esac
  if ! out="$(yq -i "$3" "$target" 2>&1)"; then
    fail_case "$1" "the fixture edit does not apply to $2: ${out}"
    return 0
  fi
  out="$(docs_violations "$d"; refresh_violations "$r")"
  case "$out" in
    *"$4"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$4', got: ${out:-<none>}" ;;
  esac
}

case_real_workflows() {
  local out
  out="$(docs_violations "$docs"; refresh_violations "$refresh")"
  if [ -n "$out" ]; then
    fail_case "docs-refresh-reported-once" "$out"
    return 0
  fi
  pass_case "docs-refresh-reported-once"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  expect_caught "fixture-report-input-ignored-caught" cd-docs.yml \
    '.jobs.report.if = "always() && github.ref != '"'"'refs/heads/main'"'"'"' \
    "cd-docs.yml report: the if: has no top-level inputs.report"
  expect_caught "fixture-report-input-under-or-caught" cd-docs.yml \
    '.jobs.report.if = "always() && (inputs.report || github.ref == '"'"'refs/heads/develop'"'"')"' \
    "cd-docs.yml report: the if: has no top-level inputs.report"
  expect_caught "fixture-nested-call-reports-caught" cd-docs-refresh.yml \
    'del(.jobs.refresh.with.report)' \
    "cd-docs-refresh.yml refresh: does not pass report: false (null)"
  expect_caught "fixture-nested-call-without-key-caught" cd-docs-refresh.yml \
    'del(.jobs.refresh.secrets.APP_PRIVATE_KEY)' \
    "cd-docs-refresh.yml refresh: does not forward APP_PRIVATE_KEY: <unset>"
  expect_caught "fixture-nested-call-inherit-caught" cd-docs-refresh.yml \
    '.jobs.refresh.secrets = "inherit"' \
    "cd-docs-refresh.yml refresh: does not forward APP_CLIENT_ID: <unset>"
  expect_caught "fixture-refresh-not-reported-caught" cd-docs-refresh.yml \
    'del(.jobs.report)' \
    "cd-docs-refresh.yml: has no single ops-report step for docs-refresh"
}

case_real_workflows
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
