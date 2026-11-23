#!/usr/bin/env bash
#
# Test that cd-docs.yml's reporting job reports no release push (issue
# #1362, epic vergil-project/.github#1494, spec §4.1).
#
# A push to main, and a develop push whose head commit merges a release/*
# branch (a release's merge back into develop), come from a release a person
# runs and watches; epic vergil-project/.github#1440's release records
# already track and recover those runs' failed CD jobs, so an ops issue would
# track the same failure twice. Every other develop push, the merges of
# self-merging automation PRs included, is reported as docs-deploy-develop.
#
# Framework-free and developer-runnable: `bash release-push-skip.test.sh`.
# CI runs it from .github/workflows/smoke-ops-report.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rule, checked on cd-docs.yml's `report` job: its `if:` is a top-level
# `&&` of conditions, `always()` first, and among them are
#   * github.ref != 'refs/heads/main', and
#   * the negated release-merge test: the head commit message starts with
#     `Merge pull request #` and contains ` from <owner>/release/`.
# A condition that sits inside an `||` or a parenthesis does not count: only
# a top-level conjunct turns the job off on its own. Fixture copies of the
# workflow check that the rule catches each condition's loss.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
real="${repo_root}/.github/workflows/cd-docs.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'release-push-skip.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$real" ]; then
  printf 'release-push-skip.test.sh: missing %s\n' "$real" >&2
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

# shellcheck disable=SC2016 # literal GitHub Actions expressions
main_skip="github.ref != 'refs/heads/main'"
# shellcheck disable=SC2016 # literal GitHub Actions expressions
release_skip="!(startsWith(github.event.head_commit.message, 'Merge pull request #') && contains(github.event.head_commit.message, format(' from {0}/release/', github.repository_owner)))"

# shellcheck source=actions/ops/report/tests/conjuncts.sh
. "${here}/conjuncts.sh"

# violations <workflow file> — print one line per missing condition.
violations() {
  local wf="$1" cond parts want
  cond="$(yq -r '.jobs.report.if // ""' "$wf")"
  if [ -z "$cond" ]; then
    printf 'report has no if:\n'
    return 0
  fi
  parts="$(conjuncts "$cond")"
  if [ "$(head -n 1 <<<"$parts")" != "always()" ]; then
    printf 'report: the if: does not start with always(): %s\n' "$cond"
  fi
  for want in "$main_skip" "$release_skip"; do
    if ! grep -qxF -- "$want" <<<"$parts"; then
      printf 'report: the if: has no top-level condition %s\n' "$want"
    fi
  done
}

# expect_caught <case> <yq edit> <substring of the expected violation>
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
  local out
  out="$(violations "$real")"
  if [ -n "$out" ]; then
    fail_case "cd-docs-report-skips-release-pushes" "$out"
    return 0
  fi
  pass_case "cd-docs-report-skips-release-pushes"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  expect_caught "fixture-main-push-reported-caught" \
    ".jobs.report.if = \"always() && inputs.report && ${release_skip}\"" \
    "has no top-level condition github.ref != 'refs/heads/main'"
  expect_caught "fixture-release-merge-reported-caught" \
    ".jobs.report.if = \"always() && inputs.report && ${main_skip}\"" \
    "has no top-level condition !(startsWith("
  expect_caught "fixture-main-skip-under-or-caught" \
    ".jobs.report.if = \"always() && (inputs.report || ${main_skip}) && ${release_skip}\"" \
    "has no top-level condition github.ref != 'refs/heads/main'"
  expect_caught "fixture-no-always-caught" \
    ".jobs.report.if = \"${main_skip} && ${release_skip}\"" \
    "report: the if: does not start with always()"
  expect_caught "fixture-no-if-caught" \
    'del(.jobs.report.if)' \
    "report has no if:"
}

case_real_workflow
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
