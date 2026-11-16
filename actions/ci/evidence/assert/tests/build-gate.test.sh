#!/usr/bin/env bash
#
# Behavioural test for build-gate.sh — the quality evidence gate's decision on
# the `build` job of ci-quality.yml (epic vergil-project/.github#1174, Task 6).
#
# The `build` job runs only when vergil-tooling turns BUILD on for the repo's
# language (`vrg-ci-resolve`'s `build-enabled`). The gate passes for exactly
# two pairs: BUILD off and the job skipped, or BUILD on and the job succeeded.
# Every other pair fails with an `::error::` naming what is wrong, so a skipped
# build that should have run, or a build that ran with BUILD off, never leaves
# quality / evidence green.
#
# Framework-free and developer-runnable: `bash build-gate.test.sh`. It needs
# only bash. CI runs it from .github/workflows/smoke-setup-vergil.yml.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate_sh="${here}/../build-gate.sh"

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

# case_pair <build-enabled> <build-result> <expected exit> [<stderr needle>]
# Runs the gate on one pair and checks its exit status. A failing pair must
# print an ::error:: containing <needle>; a passing pair prints no error.
case_pair() {
  local enabled="$1" result="$2" want="$3" needle="${4:-}"
  local name="build-gate(${enabled:-<empty>},${result:-<empty>})-exits-${want}"
  local rc=0 err
  err="$(bash "$gate_sh" "$enabled" "$result" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    fail_case "$name" "expected exit ${want}, got ${rc}; stderr: ${err}"
    return 0
  fi
  if [ "$want" -ne 0 ]; then
    case "$err" in
      *"::error::"*"$needle"*) ;;
      *)
        fail_case "$name" "expected ::error:: containing '${needle}', got '${err}'"
        return 0
        ;;
    esac
  elif [ -n "$err" ]; then
    fail_case "$name" "a passing pair printed to stderr: ${err}"
    return 0
  fi
  pass_case "$name"
}

# The two passing pairs.
case_pair false skipped 0
case_pair true success 0

# BUILD on, but the job did not succeed.
case_pair true skipped 1 "BUILD is on"
case_pair true failure 1 "BUILD is on"
case_pair true cancelled 1 "BUILD is on"

# BUILD off, but the job did not skip.
case_pair false success 1 "BUILD is off"
case_pair false failure 1 "BUILD is off"
case_pair false cancelled 1 "BUILD is off"

# A flag that is neither "true" nor "false" is an error, never read as off.
case_pair "" skipped 1 "build-enabled"
case_pair "" success 1 "build-enabled"
case_pair yes success 1 "build-enabled"
case_pair True success 1 "build-enabled"

# A result GitHub never reports is an error.
case_pair true "" 1 "build result"
case_pair false "" 1 "build result"
case_pair true passed 1 "build result"

# The wrong number of arguments is a usage error.
usage_rc=0
bash "$gate_sh" true >/dev/null 2>&1 || usage_rc=$?
if [ "$usage_rc" -eq 2 ]; then
  pass_case "build-gate-one-argument-exits-2"
else
  fail_case "build-gate-one-argument-exits-2" "expected exit 2, got ${usage_rc}"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
