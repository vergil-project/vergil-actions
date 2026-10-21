#!/usr/bin/env bash
#
# Behavioural test for read-pin.sh — the setup action's reader for the pinned
# vergil-tooling tag (`[dependencies].vergil` in vergil.toml).
#
# Framework-free and developer-runnable, like derive.test.sh: run it directly
# with `bash read-pin.test.sh`. It needs only python3 on PATH (the same
# dependency read-pin.sh has).
#
# Each case builds a fixture directory (with or without a vergil.toml), runs
# read-pin.sh with VERGIL_CONFIG_DIR pointed at it, and asserts the exit
# status, the tag on stdout, and — for the failure cases — that stderr carries
# a single clean `::error::` annotation and no Python traceback (issue #977).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_pin_sh="${here}/../read-pin.sh"

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

# Set by run_read_pin.
status=0
stdout=""
stderr=""

# run_read_pin <vergil.toml body | __NO_FILE__>
# Runs read-pin.sh against a fixture dir and records status/stdout/stderr.
run_read_pin() {
  local dir out err
  dir="$(mktemp -d)"
  out="$(mktemp)"
  err="$(mktemp)"
  if [ "$1" != "__NO_FILE__" ]; then
    printf '%s\n' "$1" >"${dir}/vergil.toml"
  fi
  status=0
  VERGIL_CONFIG_DIR="$dir" bash "$read_pin_sh" >"$out" 2>"$err" || status=$?
  stdout="$(cat "$out")"
  stderr="$(cat "$err")"
  rm -rf "$dir" "$out" "$err"
}

# assert_clean_error <name> <substring>...
# The run failed, printed nothing on stdout, emitted an ::error:: annotation
# containing every given substring, and carried no Python traceback.
assert_clean_error() {
  local name="$1" needle
  shift
  if [ "$status" -eq 0 ]; then
    fail_case "$name" "expected non-zero exit, got 0 (stdout '$stdout')"
    return 1
  fi
  if [ -n "$stdout" ]; then
    fail_case "$name" "expected empty stdout, got '$stdout'"
    return 1
  fi
  case "$stderr" in
    *Traceback*)
      fail_case "$name" "stderr carries a Python traceback: $stderr"
      return 1
      ;;
  esac
  case "$stderr" in
    ::error::*) ;;
    *)
      fail_case "$name" "stderr does not start with ::error::, got '$stderr'"
      return 1
      ;;
  esac
  for needle in "$@"; do
    case "$stderr" in
      *"$needle"*) ;;
      *)
        fail_case "$name" "stderr missing '$needle', got '$stderr'"
        return 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Case 1: a pinned tag is printed verbatim on stdout, exit 0.
# ---------------------------------------------------------------------------
case_pinned() {
  local name="pinned-tag"
  run_read_pin '[dependencies]
vergil = "v2.1"'
  if [ "$status" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got $status (stderr '$stderr')"
    return
  fi
  if [ "$stdout" != "v2.1" ]; then
    fail_case "$name" "expected 'v2.1', got '$stdout'"
    return
  fi
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 2: no vergil.toml at all — names the file and says what to add.
# ---------------------------------------------------------------------------
case_missing_file() {
  local name="missing-file"
  run_read_pin __NO_FILE__
  assert_clean_error "$name" "vergil.toml not found" '[dependencies]' \
    'vergil = "v2.1"' || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 3: vergil.toml with no [dependencies] section — names the key.
# ---------------------------------------------------------------------------
case_missing_section() {
  local name="missing-dependencies-section"
  run_read_pin '[ci]
versions = ["latest"]'
  assert_clean_error "$name" "[dependencies].vergil" "missing" \
    'vergil = "v2.1"' || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 4: [dependencies] present but no vergil key — names the key.
# ---------------------------------------------------------------------------
case_missing_key() {
  local name="missing-vergil-key"
  run_read_pin '[dependencies]
other = "x"'
  assert_clean_error "$name" "[dependencies].vergil" "missing" \
    'vergil = "v2.1"' || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 5: the key is an empty string — still a clean, specific error.
# ---------------------------------------------------------------------------
case_empty_value() {
  local name="empty-vergil-value"
  run_read_pin '[dependencies]
vergil = ""'
  assert_clean_error "$name" "[dependencies].vergil" "empty" \
    'vergil = "v2.1"' || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 6: the key is not a string — clean error, not a crash downstream.
# ---------------------------------------------------------------------------
case_non_string_value() {
  local name="non-string-vergil-value"
  run_read_pin '[dependencies]
vergil = 2'
  assert_clean_error "$name" "[dependencies].vergil" "string" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 7: [dependencies] is not a table — clean error, not a TypeError.
# ---------------------------------------------------------------------------
case_dependencies_not_table() {
  local name="dependencies-not-a-table"
  run_read_pin 'dependencies = "v2.1"'
  assert_clean_error "$name" "[dependencies]" "table" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 8: vergil.toml is not valid TOML — clean error naming the file.
# ---------------------------------------------------------------------------
case_invalid_toml() {
  local name="invalid-toml"
  run_read_pin '[dependencies
vergil = "v2.1"'
  assert_clean_error "$name" "vergil.toml" "not valid TOML" || return
  pass_case "$name"
}

case_pinned
case_missing_file
case_missing_section
case_missing_key
case_empty_value
case_non_string_value
case_dependencies_not_table
case_invalid_toml

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
