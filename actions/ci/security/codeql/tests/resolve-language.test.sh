#!/usr/bin/env bash
#
# Behavioural test for resolve-language.sh — the primary-language ->
# CodeQL-analysis-language mapping (epic vergil-project/.github#284 §6 point 8a).
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash resolve-language.test.sh`.
#
# Each case runs resolve-language.sh with a GITHUB_OUTPUT temp file and asserts
# the resolved `codeql_language`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_sh="${here}/../resolve-language.sh"

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

# assert_maps <name> <language> <expected-codeql-language>
assert_maps() {
  local name="$1" language="$2" expected="$3" out actual
  out="$(mktemp)"
  GITHUB_OUTPUT="$out" LANGUAGE="$language" bash "$resolve_sh" >/dev/null
  actual="$(sed -n 's/^codeql_language=//p' "$out")"
  rm -f "$out"
  if [ "$actual" != "$expected" ]; then
    fail_case "$name" "expected '$expected', got '$actual'"
    return
  fi
  pass_case "$name"
}

# The pushback fix: bare `typescript` is not a valid CodeQL analysis language.
assert_maps "typescript->javascript-typescript" typescript javascript-typescript
# cpp routed through the same table to the current canonical identifier.
assert_maps "cpp->c-cpp" cpp c-cpp
# Valid CodeQL identifiers pass through unchanged.
assert_maps "python passthrough" python python
assert_maps "go passthrough" go go
assert_maps "java passthrough" java java

# Missing LANGUAGE fails closed (set -u / :? guard), never emitting a silent
# empty mapping.
case_missing_language() {
  local name="missing-language-fails-closed" out rc
  out="$(mktemp)"
  set +e
  # env -u LANGUAGE: the parent shell may export LANGUAGE as a GNU locale var;
  # strip it so this exercises the genuinely-unset path.
  env -u LANGUAGE GITHUB_OUTPUT="$out" bash "$resolve_sh" >/dev/null 2>&1
  rc=$?
  set -e
  rm -f "$out"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected non-zero exit when LANGUAGE is unset, got 0"
    return
  fi
  pass_case "$name"
}
case_missing_language

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
