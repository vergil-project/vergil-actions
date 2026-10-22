#!/usr/bin/env bash
#
# Behavioural test for resolve.sh — the CI matrix built from the resolver's
# answer (versions, primary version, container tags and suffixes), with the
# per-kind cardinality collapse.
#
# Framework-free and developer-runnable: `bash resolve.test.sh`. It needs only
# `jq` on PATH (the same dependency resolve.sh has).
#
# Each case runs resolve.sh with a GITHUB_OUTPUT temp file and the input env,
# then asserts the resolved `all` / `once` JSON, or for the failure cases the
# exit status and the `::error::` annotation.
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

# Result of the last run_resolve.
rc=0
all=""
once=""
stderr=""

# run_resolve <language> <versions> <primary> <tags> <suffixes> <prefix> <suffix>
run_resolve() {
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  rc=0
  GITHUB_OUTPUT="$out" \
    LANGUAGE="$1" VERSIONS="$2" PRIMARY="$3" CONTAINER_TAGS="$4" \
    CONTAINER_SUFFIXES="$5" PREFIX="$6" SUFFIX="$7" \
    bash "$resolve_sh" >/dev/null 2>"$err" || rc=$?
  all="$(sed -n 's/^all=//p' "$out")"
  once="$(sed -n 's/^once=//p' "$out")"
  stderr="$(cat "$err")"
  rm -f "$out" "$err"
}

# assert_json <name> <actual> <expected>  (compares as JSON, order-sensitive)
assert_json() {
  local name="$1" actual="$2" expected="$3"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 1
  fi
  if jq -e --argjson a "$actual" --argjson e "$expected" -n '$a == $e' >/dev/null; then
    return 0
  fi
  fail_case "$name" "expected $expected, got $actual"
  return 1
}

# assert_error <name> <substring>
assert_error() {
  local name="$1" needle="$2"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected a non-zero exit, got 0"
    return 1
  fi
  case "$stderr" in
    *"::error::"*"$needle"*) ;;
    *)
      fail_case "$name" "expected ::error:: containing '$needle', got '$stderr'"
      return 1
      ;;
  esac
  if [ -n "$all" ] || [ -n "$once" ]; then
    fail_case "$name" "a failed run wrote outputs: all=$all once=$once"
    return 1
  fi
}

reg="ghcr.io/vergil-project"
cpp_tags='{"clang-20":"20","gcc-14":"14"}'
cpp_suffixes='{"clang-20":"cpp-clang","gcc-14":"cpp-gcc"}'

# ---------------------------------------------------------------------------
# matrix_uses_container_tags: C++ images come from the resolver's tags and
# suffixes, not from splitting the version token; once = the primary.
# ---------------------------------------------------------------------------
case_container_tags() {
  local name="matrix_uses_container_tags"
  run_resolve cpp '["clang-20","gcc-14"]' clang-20 "$cpp_tags" "$cpp_suffixes" prod cpp-clang
  assert_json "$name (all)" "$all" "[
    {\"version\":\"clang-20\",\"image\":\"$reg/prod-cpp-clang:20\"},
    {\"version\":\"gcc-14\",\"image\":\"$reg/prod-cpp-gcc:14\"}]" || return 0
  assert_json "$name (once)" "$once" \
    "[{\"version\":\"clang-20\",\"image\":\"$reg/prod-cpp-clang:20\"}]" || return 0
  pass_case "$name"
}

# The tag is whatever the resolver says, even where splitting the token would
# give something else: the matrix never derives a tag itself.
case_tag_not_derived() {
  local name="tag-not-derived-from-token"
  run_resolve cpp '["clang-20"]' clang-20 '{"clang-20":"20-bookworm"}' \
    '{"clang-20":"cpp-clang"}' prod ''
  assert_json "$name" "$all" \
    "[{\"version\":\"clang-20\",\"image\":\"$reg/prod-cpp-clang:20-bookworm\"}]" || return 0
  pass_case "$name"
}

# Run-once kinds follow the primary version, wherever it sits in the list.
case_once_follows_primary() {
  local name="once-follows-primary"
  run_resolve cpp '["clang-20","gcc-14"]' gcc-14 "$cpp_tags" "$cpp_suffixes" prod ''
  assert_json "$name" "$once" \
    "[{\"version\":\"gcc-14\",\"image\":\"$reg/prod-cpp-gcc:14\"}]" || return 0
  pass_case "$name"
}

# TypeScript: node-<major> tokens, ts-node suffix, dev prefix, once collapse.
case_typescript() {
  local name="typescript"
  run_resolve typescript '["node-24","node-22"]' node-24 '{"node-24":"24","node-22":"22"}' \
    '{"node-24":"ts-node","node-22":"ts-node"}' dev ts-node
  assert_json "$name (all)" "$all" "[
    {\"version\":\"node-24\",\"image\":\"$reg/dev-ts-node:24\"},
    {\"version\":\"node-22\",\"image\":\"$reg/dev-ts-node:22\"}]" || return 0
  assert_json "$name (once)" "$once" \
    "[{\"version\":\"node-24\",\"image\":\"$reg/dev-ts-node:24\"}]" || return 0
  pass_case "$name"
}

# Python: one image per version, and once == all (no run-once collapse).
case_python() {
  local name="python"
  run_resolve python '["3.14","3.13"]' 3.14 '{"3.14":"3.14","3.13":"3.13"}' \
    '{"3.14":"python","3.13":"python"}' prod python
  assert_json "$name (all)" "$all" "[
    {\"version\":\"3.14\",\"image\":\"$reg/prod-python:3.14\"},
    {\"version\":\"3.13\",\"image\":\"$reg/prod-python:3.13\"}]" || return 0
  assert_json "$name (once==all)" "$once" "$all" || return 0
  pass_case "$name"
}

# A repo with no language: the base image at latest.
case_no_language() {
  local name="no-language"
  run_resolve shell '["latest"]' latest '{"latest":"latest"}' '{"latest":"base"}' dev base
  assert_json "$name" "$all" "[{\"version\":\"latest\",\"image\":\"$reg/dev-base:latest\"}]" \
    || return 0
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Failures: loud, with no outputs written.
# ---------------------------------------------------------------------------
case_suffix_mismatch() {
  local name="container-suffix-mismatch"
  run_resolve python '["latest"]' latest '{"latest":"latest"}' '{"latest":"base"}' prod python
  assert_error "$name" "container-suffix 'python' is not an image suffix" || return 0
  pass_case "$name"
}

case_missing_tag() {
  local name="missing-tag"
  run_resolve cpp '["clang-20","gcc-14"]' clang-20 '{"clang-20":"20"}' "$cpp_suffixes" prod ''
  assert_error "$name" "container-tags has no tag for gcc-14" || return 0
  pass_case "$name"
}

case_missing_suffix() {
  local name="missing-suffix"
  run_resolve cpp '["clang-20","gcc-14"]' clang-20 "$cpp_tags" '{"clang-20":"cpp-clang"}' prod ''
  assert_error "$name" "container-suffixes has no suffix for gcc-14" || return 0
  pass_case "$name"
}

case_primary_not_resolved() {
  local name="primary-not-resolved"
  run_resolve cpp '["clang-20","gcc-14"]' clang-19 "$cpp_tags" "$cpp_suffixes" prod ''
  assert_error "$name" "primary-version clang-19 is not one of the versions" || return 0
  pass_case "$name"
}

case_empty_input() {
  local name="empty-input"
  run_resolve python '["3.14"]' 3.14 '' '{"3.14":"python"}' prod python
  assert_error "$name" "CONTAINER_TAGS is empty" || return 0
  pass_case "$name"
}

case_empty_versions() {
  local name="empty-versions"
  run_resolve python '[]' 3.14 '{}' '{}' prod python
  assert_error "$name" "versions must be a non-empty JSON array" || return 0
  pass_case "$name"
}

case_container_tags
case_tag_not_derived
case_once_follows_primary
case_typescript
case_python
case_no_language
case_suffix_mismatch
case_missing_tag
case_missing_suffix
case_primary_not_resolved
case_empty_input
case_empty_versions

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
