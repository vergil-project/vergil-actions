#!/usr/bin/env bash
#
# Behavioural test for detect.sh — the package setup action's vergil-tooling
# install-spec resolver.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash detect.test.sh`. It needs uv or python3 (3.11+) on
# PATH (the same dependency detect.sh has).
#
# Each case writes fixture pyproject.toml / vergil.toml files into a temp dir,
# runs detect.sh against it, and asserts the printed spec (or the failure).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
detect_sh="${here}/../detect.sh"

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

# assert_eq <name> <actual> <expected>
assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    return 0
  fi
  fail_case "$name" "expected '$expected', got '$actual'"
  return 1
}

# fixture <pyproject.toml body or ""> <vergil.toml body or "">
# Echoes a fresh temp dir holding the non-empty fixture files.
fixture() {
  local dir
  dir="$(mktemp -d)"
  [ -z "$1" ] || printf '%s\n' "$1" >"${dir}/pyproject.toml"
  [ -z "$2" ] || printf '%s\n' "$2" >"${dir}/vergil.toml"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Case 1: the vergil-tooling repo itself installs from its own checkout.
# ---------------------------------------------------------------------------
case_self_repo() {
  local name="self-repo" dir out
  dir="$(fixture '[project]
name = "vergil-tooling"
version = "2.1.227"' '[dependencies]
vergil = "v2.1"')"
  out="$(bash "$detect_sh" "$dir")"
  rm -rf "$dir"
  assert_eq "$name" "$out" "$dir" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 2: any other repo installs the release line pinned in
# [dependencies].vergil, even when it has a pyproject.toml of its own.
# ---------------------------------------------------------------------------
case_consumer_repo() {
  local name="consumer-repo" dir out
  dir="$(fixture '[project]
name = "vergil-python"' '[project]
repository-type = "library"

[dependencies]
vergil = "v2.1"')"
  out="$(bash "$detect_sh" "$dir")"
  rm -rf "$dir"
  assert_eq "$name" "$out" \
    "vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 3: a non-Python consumer (no pyproject.toml) with an exact pin.
# ---------------------------------------------------------------------------
case_consumer_no_pyproject() {
  local name="consumer-no-pyproject" dir out
  dir="$(fixture '' '[dependencies]
vergil = "v2.1.226"')"
  out="$(bash "$detect_sh" "$dir")"
  rm -rf "$dir"
  assert_eq "$name" "$out" \
    "vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1.226" || return
  pass_case "$name"
}

# expect_failure <name> <dir>
# Asserts detect.sh exits nonzero against <dir> and prints nothing on stdout.
expect_failure() {
  local name="$1" dir="$2" out rc=0
  out="$(bash "$detect_sh" "$dir" 2>/dev/null)" || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected a nonzero exit, got 0 (stdout '$out')"
    return 1
  fi
  assert_eq "$name" "$out" "" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 4: no vergil.toml is fatal, never a silent default.
# ---------------------------------------------------------------------------
case_missing_vergil_toml() {
  expect_failure "missing-vergil-toml" "$(fixture '' '')"
}

# ---------------------------------------------------------------------------
# Case 5: vergil.toml without [dependencies].vergil is fatal.
# ---------------------------------------------------------------------------
case_missing_dependency() {
  expect_failure "missing-dependency" "$(fixture '' '[project]
repository-type = "library"')"
}

case_self_repo
case_consumer_repo
case_consumer_no_pyproject
case_missing_vergil_toml
case_missing_dependency

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
