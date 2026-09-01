#!/usr/bin/env bash
#
# Behavioural test for derive.sh — the setup action's CI version resolver.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash derive.test.sh`. It needs only python3 on PATH (the
# same dependency derive.sh has).
#
# Each case writes a fixture vergil.toml into a temp dir, runs derive.sh with a
# temp GITHUB_OUTPUT and VERGIL_CONFIG_DIR pointed at the fixture, then asserts
# the resolved `versions` / `primary-version` outputs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
derive_sh="${here}/../derive.sh"

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

# run_derive <vergil.toml body>
# Echoes: "<versions>\t<primary-version>" read back from the GITHUB_OUTPUT file.
run_derive() {
  local dir out versions primary
  dir="$(mktemp -d)"
  out="$(mktemp)"
  printf '%s\n' "$1" >"${dir}/vergil.toml"
  GITHUB_OUTPUT="$out" VERGIL_CONFIG_DIR="$dir" bash "$derive_sh" >/dev/null
  versions="$(sed -n 's/^versions=//p' "$out")"
  primary="$(sed -n 's/^primary-version=//p' "$out")"
  rm -rf "$dir" "$out"
  printf '%s\t%s' "$versions" "$primary"
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

# ---------------------------------------------------------------------------
# Case 1: multi-version python — versions preserved in order; primary = max.
# ---------------------------------------------------------------------------
case_multi_version() {
  local name="multi-version" res versions primary
  res="$(run_derive '[ci]
versions = ["3.12", "3.13", "3.14"]')"
  versions="${res%$'\t'*}"
  primary="${res#*$'\t'}"
  assert_eq "$name (versions)" "$versions" '["3.12","3.13","3.14"]' || return
  assert_eq "$name (primary=max)" "$primary" "3.14" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 2: list order does not change the derived primary (semantic max).
# ---------------------------------------------------------------------------
case_unsorted() {
  local name="unsorted-order" res versions primary
  res="$(run_derive '[ci]
versions = ["3.14", "3.12", "3.13"]')"
  versions="${res%$'\t'*}"
  primary="${res#*$'\t'}"
  assert_eq "$name (versions preserve order)" "$versions" '["3.14","3.12","3.13"]' || return
  assert_eq "$name (primary still max)" "$primary" "3.14" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 3: single version — versions is a one-element array; primary is it.
# ---------------------------------------------------------------------------
case_single_version() {
  local name="single-version" res versions primary
  res="$(run_derive '[ci]
versions = ["latest"]')"
  versions="${res%$'\t'*}"
  primary="${res#*$'\t'}"
  assert_eq "$name (versions)" "$versions" '["latest"]' || return
  assert_eq "$name (primary)" "$primary" "latest" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 4: explicit [ci].primary-version overrides the max (escape hatch).
# ---------------------------------------------------------------------------
case_explicit_primary() {
  local name="explicit-primary" res versions primary
  res="$(run_derive '[ci]
versions = ["3.12", "3.13", "3.14"]
primary-version = "3.12"')"
  versions="${res%$'\t'*}"
  primary="${res#*$'\t'}"
  assert_eq "$name (versions)" "$versions" '["3.12","3.13","3.14"]' || return
  assert_eq "$name (primary=override)" "$primary" "3.12" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 5: numeric runs compare numerically, not lexically (clang-20 > clang-9).
# ---------------------------------------------------------------------------
case_numeric_run() {
  local name="numeric-run" res versions primary
  res="$(run_derive '[ci]
versions = ["clang-9", "clang-20"]')"
  versions="${res%$'\t'*}"
  primary="${res#*$'\t'}"
  assert_eq "$name (versions)" "$versions" '["clang-9","clang-20"]' || return
  assert_eq "$name (primary=numeric max)" "$primary" "clang-20" || return
  pass_case "$name"
}

case_multi_version
case_unsorted
case_single_version
case_explicit_primary
case_numeric_run

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
