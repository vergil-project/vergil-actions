#!/usr/bin/env bash
#
# Behavioural test for resolve.sh — the CI matrix resolver's image routing and
# per-kind cardinality collapse.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash resolve.test.sh`. It needs only `jq` on PATH (the same
# dependency resolve.sh has).
#
# Each case runs resolve.sh with a GITHUB_OUTPUT temp file and the input env,
# then asserts the resolved `all` / `once` JSON against expected values.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_sh="${here}/../resolve.sh"

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

# run_resolve <language> <versions-json> <prefix> <suffix>
# Echoes: "<all-json>\t<once-json>" read back from the GITHUB_OUTPUT file.
run_resolve() {
  local out all once
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" \
    LANGUAGE="$1" VERSIONS="$2" PREFIX="$3" SUFFIX="$4" \
    bash "$resolve_sh" >/dev/null
  all="$(sed -n 's/^all=//p' "$out")"
  once="$(sed -n 's/^once=//p' "$out")"
  rm -f "$out"
  printf '%s\t%s' "$all" "$once"
}

# assert_json <name> <actual> <expected>  (compares as JSON, order-sensitive)
assert_json() {
  local name="$1" actual="$2" expected="$3"
  if jq -e --argjson a "$actual" --argjson e "$expected" -n '$a == $e' >/dev/null; then
    return 0
  fi
  fail_case "$name" "expected $expected, got $actual"
  return 1
}

reg="ghcr.io/vergil-project"

# ---------------------------------------------------------------------------
# Case 1: TypeScript — node-<major> tokens route to prod-ts-node:<major>, and
# TYPECHECK/LINT/AUDIT collapse to the primary (node-24) via `once`.
# ---------------------------------------------------------------------------
case_typescript() {
  local name="typescript-node-routing" res all once
  res="$(run_resolve typescript '["node-24","node-22"]' prod ts-node)"
  all="${res%$'\t'*}"
  once="${res#*$'\t'}"
  assert_json "$name (all)" "$all" "$(cat <<EOF
[{"version":"node-24","image":"$reg/prod-ts-node:24"},
 {"version":"node-22","image":"$reg/prod-ts-node:22"}]
EOF
)" || return
  assert_json "$name (once)" "$once" \
    "[{\"version\":\"node-24\",\"image\":\"$reg/prod-ts-node:24\"}]" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 2: TypeScript with an empty suffix falls back to the `ts-<family>`
# runtime family derived from the version token.
# ---------------------------------------------------------------------------
case_typescript_empty_suffix() {
  local name="typescript-empty-suffix-fallback" res all
  res="$(run_resolve typescript '["node-24"]' prod '')"
  all="${res%$'\t'*}"
  assert_json "$name" "$all" \
    "[{\"version\":\"node-24\",\"image\":\"$reg/prod-ts-node:24\"}]" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 3: TypeScript honours the dev prefix.
# ---------------------------------------------------------------------------
case_typescript_dev_prefix() {
  local name="typescript-dev-prefix" res all
  res="$(run_resolve typescript '["node-22"]' dev ts-node)"
  all="${res%$'\t'*}"
  assert_json "$name" "$all" \
    "[{\"version\":\"node-22\",\"image\":\"$reg/dev-ts-node:22\"}]" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 4: C++ regression — compiler-family routing and the once-collapse are
# unchanged by the TypeScript addition.
# ---------------------------------------------------------------------------
case_cpp_regression() {
  local name="cpp-regression" res all once
  res="$(run_resolve cpp '["clang-20","gcc-14"]' prod '')"
  all="${res%$'\t'*}"
  once="${res#*$'\t'}"
  assert_json "$name (all)" "$all" "$(cat <<EOF
[{"version":"clang-20","image":"$reg/prod-cpp-clang:20"},
 {"version":"gcc-14","image":"$reg/prod-cpp-gcc:14"}]
EOF
)" || return
  assert_json "$name (once)" "$once" \
    "[{\"version\":\"clang-20\",\"image\":\"$reg/prod-cpp-clang:20\"}]" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 5: Single-suffix language (python) — no token split, and once == all
# (no run-once collapse).
# ---------------------------------------------------------------------------
case_python_regression() {
  local name="python-regression" res all once
  res="$(run_resolve python '["3.12","3.13"]' prod python)"
  all="${res%$'\t'*}"
  once="${res#*$'\t'}"
  assert_json "$name (all)" "$all" "$(cat <<EOF
[{"version":"3.12","image":"$reg/prod-python:3.12"},
 {"version":"3.13","image":"$reg/prod-python:3.13"}]
EOF
)" || return
  assert_json "$name (once==all)" "$once" "$all" || return
  pass_case "$name"
}

case_typescript
case_typescript_empty_suffix
case_typescript_dev_prefix
case_cpp_regression
case_python_regression

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
