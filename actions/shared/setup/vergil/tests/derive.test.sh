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

# run_derive_tag <vergil.toml body> [language]
# Echoes the resolved `primary-container-tag` output. The optional LANGUAGE
# mirrors the workflow's `inputs.language` (the setup action plumbs it into
# derive.sh); an empty language falls through to the verbatim tag.
run_derive_tag() {
  local dir out tag
  dir="$(mktemp -d)"
  out="$(mktemp)"
  printf '%s\n' "$1" >"${dir}/vergil.toml"
  GITHUB_OUTPUT="$out" VERGIL_CONFIG_DIR="$dir" LANGUAGE="${2:-}" \
    bash "$derive_sh" >/dev/null
  tag="$(sed -n 's/^primary-container-tag=//p' "$out")"
  rm -rf "$dir" "$out"
  printf '%s' "$tag"
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

# ---------------------------------------------------------------------------
# Case 6: primary-container-tag — C++ clang family. The version token carries
# the compiler family (clang-20); the published image tag is the NUMERIC part
# (20), which rides in the tag while the family rides container-suffix
# (cpp-clang). Mirrors actions/ci/matrix/resolve.sh's cpp routing so the
# single-container jobs resolve prod-cpp-clang:20, not the nonexistent
# prod-cpp-clang:clang-20 (issue #893).
# ---------------------------------------------------------------------------
case_container_tag_cpp_clang() {
  local name="container-tag-cpp-clang" tag
  tag="$(run_derive_tag '[ci]
versions = ["clang-20"]' cpp)"
  assert_eq "$name" "$tag" "20" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 7: primary-container-tag — C++ gcc family. Same split, family-agnostic:
# gcc-14 -> 14 (the family is carried by container-suffix cpp-gcc).
# ---------------------------------------------------------------------------
case_container_tag_cpp_gcc() {
  local name="container-tag-cpp-gcc" tag
  tag="$(run_derive_tag '[ci]
versions = ["gcc-14"]' cpp)"
  assert_eq "$name" "$tag" "14" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 8: primary-container-tag — python. Not family-prefixed, so the tag is
# the primary version verbatim (3.14 from the multi-version set).
# ---------------------------------------------------------------------------
case_container_tag_python() {
  local name="container-tag-python" tag
  tag="$(run_derive_tag '[ci]
versions = ["3.12", "3.13", "3.14"]' python)"
  assert_eq "$name" "$tag" "3.14" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 9: primary-container-tag — shell. Single "latest" version, verbatim.
# ---------------------------------------------------------------------------
case_container_tag_shell() {
  local name="container-tag-shell" tag
  tag="$(run_derive_tag '[ci]
versions = ["latest"]' shell)"
  assert_eq "$name" "$tag" "latest" || return
  pass_case "$name"
}

case_multi_version
case_unsorted
case_single_version
case_explicit_primary
case_numeric_run
case_container_tag_cpp_clang
case_container_tag_cpp_gcc
case_container_tag_python
case_container_tag_shell

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
