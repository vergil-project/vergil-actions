#!/usr/bin/env bash
#
# Test that a named job's skipped GitHub jobs reach the reporter (issue
# #1362, epic vergil-project/.github#1494, plan Review Focus item 4).
#
# A named job's result combines all of its GitHub jobs' results: any failure,
# else any cancelled, else at least one success is the result, and all
# skipped reports nothing at all (spec §5.3). vrg-ops-report does the
# combining (its test_combine_all_skipped_is_none pins the all-skipped
# case), so the workflow side must hand it every result unfiltered. For
# upstream-refresh, a failed prepare skips publish: the report must still run
# and see both, so it reports an upstream-refresh failure, and a run that
# skipped both reports nothing.
#
# Framework-free and developer-runnable: `bash ops-report-skipped.test.sh`.
# CI runs it from .github/workflows/smoke-ops-report.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules:
#   * ops-upstream-refresh.yml's report job runs on `if: always()` and its
#     ops-report step's `results` names both needs.prepare.result and
#     needs.publish.result;
#   * the ops-report action passes its `results` input to vrg-ops-report
#     unchanged: the report step's env sets RESULTS from
#     `${{ inputs.results }}` and its run passes `--results "${RESULTS}"`.
# Fixture copies check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
real="${repo_root}/.github/workflows/ops-upstream-refresh.yml"
action="${here}/../action.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'ops-report-skipped.test.sh needs yq on PATH\n' >&2
  exit 1
fi
for f in "$real" "$action"; do
  if [ ! -f "$f" ]; then
    printf 'ops-report-skipped.test.sh: missing %s\n' "$f" >&2
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

# workflow_violations <workflow file>
workflow_violations() {
  local wf="$1" cond results job
  cond="$(yq -r '.jobs.report.if // "<unset>"' "$wf")"
  if [ "$cond" != "always()" ]; then
    printf 'report: the if: is not always(): %s\n' "$cond"
  fi
  results="$(yq -r '[.jobs.report.steps[] | select((.uses // "") == "./actions/ops/report")
    | .with.results // ""] | join(",")' "$wf")"
  for job in prepare publish; do
    case "$results" in
      *"\${{ needs.${job}.result }}"*) ;;
      *) printf 'report: results does not include needs.%s.result: %s\n' "$job" "${results:-<unset>}" ;;
    esac
  done
}

# action_violations <action file>
action_violations() {
  local file="$1" step env run
  step='.runs.steps[] | select((.run // "") | test("vrg-ops-report"))'
  env="$(yq -r "[${step} | .env.RESULTS // \"<unset>\"] | join(\",\")" "$file")"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$env" != '${{ inputs.results }}' ]; then
    printf 'the report step RESULTS is not ${{ inputs.results }}: %s\n' "${env:-<none>}"
  fi
  run="$(yq -r "[${step} | .run] | join(\"\")" "$file")"
  # shellcheck disable=SC2016 # the literal shell argument the step must pass
  case "$run" in
    *'--results "${RESULTS}"'*) ;;
    *) printf 'the report step does not pass --results "${RESULTS}"\n' ;;
  esac
}

# expect_caught <case> <workflow|action> <yq edit> <substring>
expect_caught() {
  local file="${tmp}/$1.yml" out
  case "$2" in
    workflow) cp "$real" "$file" ;;
    *) cp "$action" "$file" ;;
  esac
  if ! out="$(yq -i "$3" "$file" 2>&1)"; then
    fail_case "$1" "the fixture edit does not apply: ${out}"
    return 0
  fi
  case "$2" in
    workflow) out="$(workflow_violations "$file")" ;;
    *) out="$(action_violations "$file")" ;;
  esac
  case "$out" in
    *"$4"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$4', got: ${out:-<none>}" ;;
  esac
}

case_real() {
  local out
  out="$(workflow_violations "$real"; action_violations "$action")"
  if [ -n "$out" ]; then
    fail_case "upstream-refresh-skipped-results-reach-the-reporter" "$out"
    return 0
  fi
  pass_case "upstream-refresh-skipped-results-reach-the-reporter"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  expect_caught "fixture-prepare-result-dropped-caught" workflow \
    '(.jobs.report.steps[] | select(.uses == "./actions/ops/report")).with.results = "${{ needs.publish.result }}"' \
    "report: results does not include needs.prepare.result"
  expect_caught "fixture-publish-result-dropped-caught" workflow \
    '(.jobs.report.steps[] | select(.uses == "./actions/ops/report")).with.results = "${{ needs.prepare.result }}"' \
    "report: results does not include needs.publish.result"
  expect_caught "fixture-report-skipped-after-failure-caught" workflow \
    '.jobs.report.if = "success()"' \
    "report: the if: is not always(): success()"
  expect_caught "fixture-action-results-filtered-caught" action \
    '(.runs.steps[] | select((.run // "") | test("vrg-ops-report"))).env.RESULTS = "${{ inputs.results != '"'"'skipped'"'"' && inputs.results || '"'"''"'"' }}"' \
    'the report step RESULTS is not ${{ inputs.results }}'
}

case_real
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
