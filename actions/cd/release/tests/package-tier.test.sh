#!/usr/bin/env bash
#
# Test ci-package's matrix tier choice (vergil-project/vergil-actions#1352,
# epic vergil-project/.github#1467): a pull request gets the full matrix
# automatically only when its head is a `release/*` branch of this same
# repository, into `main`. A fork's `release/*` head, whose branch name the
# fork's owner chooses, gets the reduced matrix like any other pull request.
#
# Framework-free and developer-runnable: `bash package-tier.test.sh`. CI runs
# it from .github/workflows/smoke-cd-release.yml. It needs `yq` (mikefarah
# v4, preinstalled on GitHub's ubuntu runners) and touches no network.
#
# Cases:
#   * the "Decide package tier" step takes the head repository from
#     `github.event.pull_request.head.repo.full_name` and this repository
#     from `github.repository` through env, never interpolated into its
#     script;
#   * the step, run as written: a same-repo `release/*` head into main gets
#     full; a fork's `release/*` or `release/post-*` head, or one whose head
#     repository is gone, gets reduced; other pull requests get reduced;
#     non-PR events get full; an explicit full or reduced input wins; any
#     other input fails.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
ci_package_yml="${repo_root}/.github/workflows/ci-package.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'package-tier.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$ci_package_yml" ]; then
  printf 'package-tier.test.sh: missing %s\n' "$ci_package_yml" >&2
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

# expect <case> <what> <got> <want> — record a mismatch; returns 1 on one.
expect() {
  if [ "$3" != "$4" ]; then
    fail_case "$1" "$2: expected '$4', got '$3'"
    return 1
  fi
}

step='.jobs.matrix.steps[] | select(.name == "Decide package tier")'

case_tier_step_wiring() {
  local name="tier-step-takes-head-repo-through-env" run
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  expect "$name" "HEAD_REPO" "$(yq -r "${step} | .env.HEAD_REPO" "$ci_package_yml")" \
    '${{ github.event.pull_request.head.repo.full_name }}' || return 0
  # shellcheck disable=SC2016
  expect "$name" "REPOSITORY" "$(yq -r "${step} | .env.REPOSITORY" "$ci_package_yml")" \
    '${{ github.repository }}' || return 0
  run="$(yq -r "${step} | .run" "$ci_package_yml")"
  # shellcheck disable=SC2016 # a literal expression opener
  case "$run" in
    *'${{'*)
      fail_case "$name" "the step's script interpolates an expression"
      return 0
      ;;
  esac
  pass_case "$name"
}

# run_tier <requested> <event> <base ref> <head ref> <head repo> — run the
# tier step as GitHub runs a bash step, with this repository
# vergil-project/example. Sets rc, out and tier.
run_tier() {
  local run
  run="$(yq -r "${step} | .run" "$ci_package_yml")"
  : >"${tmp}/output"
  set +e
  out="$(REQUESTED="$1" EVENT_NAME="$2" BASE_REF="$3" HEAD_REF="$4" \
    HEAD_REPO="$5" REPOSITORY="vergil-project/example" \
    GITHUB_OUTPUT="${tmp}/output" \
    bash --noprofile --norc -eo pipefail -c "$run" 2>&1)"
  rc=$?
  set -e
  tier="$(sed -n 's/^tier=//p' "${tmp}/output")"
}

# check_tier <case> <want> <requested> <event> <base> <head> <head repo>
check_tier() {
  local name="$1" want="$2"
  shift 2
  run_tier "$@"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "the step exited ${rc}: ${out}"
    return 1
  fi
  expect "$name" "tier" "$tier" "$want" || return 1
}

case_tier_choice() {
  local name="tier-full-only-for-same-repo-release-head"
  check_tier "$name: same-repo release head" full \
    auto pull_request main release/2.1.90 vergil-project/example || return 0
  check_tier "$name: same-repo release/post head" full \
    auto pull_request main release/post-2.1.90 vergil-project/example || return 0
  check_tier "$name: fork release head" reduced \
    auto pull_request main release/2.1.90 someone/example || return 0
  check_tier "$name: fork release/post head" reduced \
    auto pull_request main release/post-2.1.90 someone/example || return 0
  check_tier "$name: fork named like this repo's owner prefix" reduced \
    auto pull_request main release/2.1.90 vergil-project/example-fork || return 0
  check_tier "$name: head repository gone" reduced \
    auto pull_request main release/2.1.90 "" || return 0
  check_tier "$name: same-repo release head into develop" reduced \
    auto pull_request develop release/2.1.90 vergil-project/example || return 0
  check_tier "$name: same-repo task head" reduced \
    auto pull_request develop feature/1-x vergil-project/example || return 0
  check_tier "$name: fork task head" reduced \
    auto pull_request develop feature/1-x someone/example || return 0
  check_tier "$name: push" full auto push "" "" "" || return 0
  check_tier "$name: workflow_dispatch" full auto workflow_dispatch "" "" "" || return 0
  check_tier "$name: explicit full" full \
    full pull_request main release/2.1.90 someone/example || return 0
  check_tier "$name: explicit reduced" reduced \
    reduced pull_request main release/2.1.90 vergil-project/example || return 0
  run_tier bogus pull_request main release/2.1.90 vergil-project/example
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "an invalid package-tier input passed"
    return 0
  fi
  pass_case "$name"
}

case_tier_step_wiring
case_tier_choice

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
