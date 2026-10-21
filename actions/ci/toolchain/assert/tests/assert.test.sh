#!/usr/bin/env bash
#
# Behavioural test for assert.sh — the check that a CI leg runs the toolchain
# version CI resolved for it.
#
# Framework-free and developer-runnable: `bash assert.test.sh`. Each case puts
# a fake `uv` or `go` first on PATH, printing a chosen version (or failing),
# runs assert.sh, and asserts the exit status and the annotation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assert_sh="${here}/../assert.sh"

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
stdout=""
stderr=""
calls=""

# run_assert <language> <expected> <tool> <tool stdout> [<tool exit status>]
# Fakes <tool> (uv or go) to print <tool stdout> and exit with the status, and
# records the arguments it was called with in $calls.
run_assert() {
  local bin so se log
  bin="$(mktemp -d)"
  so="$(mktemp)"
  se="$(mktemp)"
  log="${bin}/calls.log"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nprintf "%%s\\n" "%s"\necho "fake %s progress" >&2\nexit %s\n' \
    "$log" "$4" "$3" "${5:-0}" >"${bin}/$3"
  chmod +x "${bin}/$3"
  rc=0
  PATH="${bin}:${PATH}" LANGUAGE="$1" EXPECTED="$2" \
    bash "$assert_sh" >"$so" 2>"$se" || rc=$?
  stdout="$(cat "$so")"
  stderr="$(cat "$se")"
  calls="$(cat "$log" 2>/dev/null || true)"
  rm -rf "$bin" "$so" "$se"
}

assert_pass() {
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  fail_case "$1" "expected exit 0, got ${rc}; stderr: ${stderr}"
  return 1
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

case_python_mismatch() {
  local name="assert_python_mismatch_fails"
  run_assert python 3.15 uv 3.14
  assert_fail "$name" "CI resolved 3.15 but the job runs 3.14" || return 0
  pass_case "$name"
}

case_python_match() {
  local name="assert_python_match_passes"
  run_assert python 3.15 uv 3.15
  assert_pass "$name" || return 0
  case "$calls" in
    "run --frozen python -c "*) ;;
    *)
      fail_case "$name" "expected 'uv run --frozen python -c ...', got '$calls'"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_python_uv_fails() {
  local name="python-uv-fails"
  run_assert python 3.14 uv "" 2
  assert_fail "$name" "assert-toolchain: cannot ask uv" || return 0
  pass_case "$name"
}

case_python_garbage() {
  local name="python-unexpected-answer"
  run_assert python 3.14 uv "not a version"
  assert_fail "$name" "assert-toolchain: unexpected answer" || return 0
  pass_case "$name"
}

case_go_match() {
  local name="assert_go_match_passes"
  run_assert go 1.26 go go1.26.3
  assert_pass "$name" || return 0
  assert_eq_calls "$name" "env GOVERSION" || return 0
  pass_case "$name"
}

assert_eq_calls() {
  if [ "$calls" = "$2" ]; then
    return 0
  fi
  fail_case "$1" "expected the tool to be called with '$2', got '$calls'"
  return 1
}

case_go_minor_only() {
  local name="go-version-without-patch"
  run_assert go 1.27 go go1.27
  assert_pass "$name" || return 0
  pass_case "$name"
}

case_go_mismatch() {
  local name="go-mismatch-fails"
  run_assert go 1.27 go go1.26.3
  assert_fail "$name" "CI resolved 1.27 but the job runs 1.26" || return 0
  pass_case "$name"
}

case_go_fails() {
  local name="go-fails"
  run_assert go 1.26 go "" 1
  assert_fail "$name" "assert-toolchain: cannot ask go" || return 0
  pass_case "$name"
}

case_bad_expected() {
  local name="expected-not-x-y"
  run_assert python latest uv 3.14
  assert_fail "$name" "assert-toolchain: expected must be an x.y version" || return 0
  pass_case "$name"
}

case_other_language() {
  local name="other-language-notice"
  run_assert cpp clang-20 uv 3.14
  assert_pass "$name" || return 0
  case "$stdout" in
    *"::notice::assert-toolchain: no toolchain assertion for language 'cpp'"*) ;;
    *)
      fail_case "$name" "expected a ::notice:: line, got '$stdout'"
      return 0
      ;;
  esac
  if [ -n "$calls" ]; then
    fail_case "$name" "a toolchain was called for cpp: '$calls'"
    return 0
  fi
  pass_case "$name"
}

case_python_mismatch
case_python_match
case_python_uv_fails
case_python_garbage
case_go_match
case_go_minor_only
case_go_mismatch
case_go_fails
case_bad_expected
case_other_language

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
