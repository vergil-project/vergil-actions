#!/usr/bin/env bash
#
# Behavioural test for pin.sh — the step that pins uv to a CI leg's Python
# interpreter — plus a structural check that every Python matrix leg in the
# CI workflows pins through it.
#
# Framework-free and developer-runnable: `bash pin.test.sh`. Each case runs
# pin.sh against a scratch GITHUB_ENV file and asserts the exit status, the
# annotation and the file's contents.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin_sh="${here}/../pin.sh"
workflows="${here}/../../../../../.github/workflows"

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

rc=0
stderr=""
env_out=""

# run_pin <version> [<existing GITHUB_ENV contents>]
run_pin() {
  local env_file se
  env_file="$(mktemp)"
  se="$(mktemp)"
  printf '%s' "${2:-}" >"$env_file"
  rc=0
  VERSION="$1" GITHUB_ENV="$env_file" bash "$pin_sh" >/dev/null 2>"$se" || rc=$?
  stderr="$(cat "$se")"
  env_out="$(cat "$env_file")"
  rm -f "$env_file" "$se"
}

# assert_fail <name> <substring of the ::error:: annotation>
assert_fail() {
  if [ "$rc" -eq 0 ]; then
    fail_case "$1" "expected a non-zero exit, got 0"
    return 1
  fi
  case "$stderr" in
    *"::error::$2"*) return 0 ;;
  esac
  fail_case "$1" "expected '::error::$2', got '$stderr'"
  return 1
}

case_pins_version_and_source() {
  local name="pins-version-and-system-source"
  run_pin 3.14
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 0
  fi
  local want
  want="$(printf 'UV_PYTHON=3.14\nUV_PYTHON_PREFERENCE=only-system')"
  if [ "$env_out" != "$want" ]; then
    fail_case "$name" "expected GITHUB_ENV '${want}', got '${env_out}'"
    return 0
  fi
  pass_case "$name"
}

case_appends() {
  local name="appends-to-existing-github-env"
  run_pin 3.12 $'EARLIER=1\n'
  local want
  want="$(printf 'EARLIER=1\nUV_PYTHON=3.12\nUV_PYTHON_PREFERENCE=only-system')"
  if [ "$rc" -ne 0 ] || [ "$env_out" != "$want" ]; then
    fail_case "$name" "rc=${rc}; expected '${want}', got '${env_out}'"
    return 0
  fi
  pass_case "$name"
}

case_bad_version() {
  local name="version-not-x-y"
  for v in "" latest 3 3.14.1 "3.14 "; do
    run_pin "$v"
    assert_fail "$name ('$v')" "pin-python: version must be an x.y" || return 0
    if [ -n "$env_out" ]; then
      fail_case "$name ('$v')" "wrote to GITHUB_ENV on error: '${env_out}'"
      return 0
    fi
  done
  pass_case "$name"
}

case_no_github_env() {
  local name="github-env-unset"
  rc=0
  stderr="$(VERSION=3.14 GITHUB_ENV="" bash "$pin_sh" 2>&1 >/dev/null)" || rc=$?
  assert_fail "$name" "pin-python: GITHUB_ENV is not set" || return 0
  pass_case "$name"
}

# Every job that runs the Python toolchain assertion must pin through this
# action first, and no workflow may set UV_PYTHON by hand (which would skip
# UV_PYTHON_PREFERENCE=only-system).
case_workflows_pin_every_python_leg() {
  local name="workflows-pin-every-python-leg"
  local wf asserts pins legs=0
  for wf in "$workflows"/*.yml; do
    if grep -q 'UV_PYTHON=' "$wf"; then
      fail_case "$name" "$(basename "$wf") sets UV_PYTHON by hand; use ./actions/ci/toolchain/pin-python"
      return 0
    fi
    asserts="$(grep -c 'uses: ./actions/ci/toolchain/assert$' "$wf" || true)"
    pins="$(grep -c 'uses: ./actions/ci/toolchain/pin-python$' "$wf" || true)"
    if [ "$asserts" != "$pins" ]; then
      fail_case "$name" "$(basename "$wf") has ${asserts} assert-toolchain step(s) but ${pins} pin-python step(s)"
      return 0
    fi
    legs=$((legs + pins))
  done
  # ci-quality lint + typecheck, ci-audit dependencies, ci-test unit.
  if [ "$legs" -ne 4 ]; then
    fail_case "$name" "expected 4 pinned Python legs, found ${legs}"
    return 0
  fi
  pass_case "$name"
}

case_pins_version_and_source
case_appends
case_bad_version
case_no_github_env
case_workflows_pin_every_python_leg

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
