#!/usr/bin/env bash
#
# Behavioural test for derive.sh — the setup action's call into the single CI
# version resolver, `vrg-ci-resolve` (epic vergil-project/.github#407).
#
# Framework-free and developer-runnable: `bash derive.test.sh`. It needs the
# real `vrg-ci-resolve` (vergil-tooling v2.1.253 or later) and `jq` on PATH.
# It does not stub the resolver: every case runs it for real against the
# fixture window in tests/fixtures/window.json, through VRG_VERSION_WINDOW, the
# resolver's one sanctioned override. So no case touches the network.
#
# Each case writes a fixture vergil.toml into a temp dir, runs derive.sh with a
# temp GITHUB_OUTPUT and VERGIL_CONFIG_DIR pointed at the fixture, and asserts
# the outputs (or, for the failure cases, the exit status, the `::error::`
# annotation, and that nothing was written to GITHUB_OUTPUT).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
derive_sh="${here}/../derive.sh"
window="${here}/fixtures/window.json"

for tool in vrg-ci-resolve jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'derive.test.sh needs %s on PATH (install vergil-tooling v2.1)\n' "$tool" >&2
    exit 1
  fi
done

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

# toml <primary-language> <repository-type> <[ci] lines> [<more sections>]
# Prints a complete vergil.toml. An empty language omits the key.
toml() {
  printf '[project]\n'
  printf 'repository-type = "%s"\n' "$2"
  printf 'versioning-scheme = "semver"\n'
  printf 'branching-model = "library-release"\n'
  printf 'release-model = "tagged-release"\n'
  if [ -n "$1" ]; then
    printf 'primary-language = "%s"\n' "$1"
  fi
  printf '\n[dependencies]\nvergil = "v2.1"\n\n'
  printf '[ci]\nintegration-tests = false\n%s\n\n' "$3"
  printf '%s\n' "${4:-}"
}

# Result of the last run_derive: exit status, stdout, stderr, and GITHUB_OUTPUT.
rc=0
stdout=""
stderr=""
output=""

# run_derive <vergil.toml body | __NO_FILE__> [env assignments...]
# Runs derive.sh against a fixture dir. By default VRG_VERSION_WINDOW points at
# the fixture window; extra NAME=value arguments are added to the environment.
#
# Options before the env assignments:
#   --input-window — pass the fixture window as VERSION_WINDOW (the action's
#                    `version-window` input) instead of VRG_VERSION_WINDOW.
#   --uv-lock      — add an empty uv.lock next to vergil.toml (a packaged
#                    Python repo must have one).
run_derive() {
  local dir out err so window_var="VRG_VERSION_WINDOW"
  dir="$(mktemp -d)"
  out="$(mktemp)"
  err="$(mktemp)"
  so="$(mktemp)"
  if [ "$1" != "__NO_FILE__" ]; then
    printf '%s\n' "$1" >"${dir}/vergil.toml"
  fi
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --input-window) window_var="VERSION_WINDOW" ;;
      --uv-lock) : >"${dir}/uv.lock" ;;
      *) break ;;
    esac
    shift
  done
  rc=0
  env -u VRG_VERSION_WINDOW -u VERSION_WINDOW \
    GITHUB_OUTPUT="$out" VERGIL_CONFIG_DIR="$dir" \
    "${window_var}=${window}" "$@" \
    bash "$derive_sh" >"$so" 2>"$err" || rc=$?
  stdout="$(cat "$so")"
  stderr="$(cat "$err")"
  output="$(cat "$out")"
  rm -rf "$dir" "$out" "$err" "$so"
}

# out <key> — a value from the last run's GITHUB_OUTPUT.
out() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p"
}

# assert_eq <name> <actual> <expected>
assert_eq() {
  if [ "$2" = "$3" ]; then
    return 0
  fi
  fail_case "$1" "expected '$3', got '$2'"
  return 1
}

# assert_ok <name> — the last run succeeded.
assert_ok() {
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  fail_case "$1" "expected exit 0, got ${rc}; stderr: ${stderr}"
  return 1
}

# assert_error <name> <substring> — the last run failed with an ::error::
# annotation containing <substring>, and wrote no outputs.
assert_error() {
  local name="$1" needle="$2"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected a non-zero exit, got 0"
    return 1
  fi
  case "$stderr" in
    *Traceback*)
      fail_case "$name" "stderr carries a Python traceback: $stderr"
      return 1
      ;;
    *"::error::"*"$needle"*) ;;
    *)
      fail_case "$name" "expected ::error:: containing '$needle', got '$stderr'"
      return 1
      ;;
  esac
  if [ -n "$output" ]; then
    fail_case "$name" "a failed run wrote outputs: $output"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# derive_uses_resolver_outputs: an unpinned Python library builds the whole
# fixture window, newest first, and every output is the resolver's answer.
# ---------------------------------------------------------------------------
case_library_window() {
  local name="derive_uses_resolver_outputs"
  run_derive "$(toml python library '')"
  assert_ok "$name" || return 0
  assert_eq "$name (versions)" "$(out versions)" '["3.15","3.14","3.13"]' || return 0
  assert_eq "$name (primary)" "$(out primary-version)" "3.15" || return 0
  assert_eq "$name (primary tag)" "$(out primary-container-tag)" "3.15" || return 0
  assert_eq "$name (tags)" "$(out container-tags)" \
    '{"3.15":"3.15","3.14":"3.14","3.13":"3.13"}' || return 0
  assert_eq "$name (suffixes)" "$(out container-suffixes)" \
    '{"3.15":"python","3.14":"python","3.13":"python"}' || return 0
  pass_case "$name"
}

# The outputs match `vrg-ci-resolve --format github-output` exactly, so the
# rendering here adds nothing of its own.
case_matches_github_output() {
  local name="derive-matches-github-output" dir expected
  dir="$(mktemp -d)"
  toml cpp library 'versions = ["gcc-14", "clang-20"]' >"${dir}/vergil.toml"
  expected="$(VRG_VERSION_WINDOW="$window" vrg-ci-resolve --format github-output \
    --repo-root "$dir" 2>/dev/null)"
  rm -rf "$dir"
  run_derive "$(toml cpp library 'versions = ["gcc-14", "clang-20"]')"
  assert_ok "$name" || return 0
  assert_eq "$name" "$(printf '%s\n' "$output" | head -n 3)" "$expected" || return 0
  pass_case "$name"
}

# An app (any type but library) builds only the newest window version.
case_app_newest() {
  local name="app-builds-newest"
  run_derive "$(toml python application '')"
  assert_ok "$name" || return 0
  assert_eq "$name (versions)" "$(out versions)" '["3.15"]' || return 0
  assert_eq "$name (primary)" "$(out primary-version)" "3.15" || return 0
  pass_case "$name"
}

# A packaged Python app builds the newest version with a published runtime
# (3.14 in the fixture; 3.15 has none) — a rule only the resolver knows.
case_packaged_app() {
  local name="packaged-app-follows-runtime"
  run_derive "$(toml python application '' '[package]
builder = "python"
vendor = "Example"
summary = "Example package"
smoke = "example --version"')" --uv-lock
  assert_ok "$name" || return 0
  assert_eq "$name (versions)" "$(out versions)" '["3.14"]' || return 0
  pass_case "$name"
}

# C++ family tokens: the resolver supplies each image tag and suffix.
case_cpp_tags() {
  local name="cpp-tags-from-resolver"
  run_derive "$(toml cpp library 'versions = ["gcc-14", "clang-20"]')"
  assert_ok "$name" || return 0
  assert_eq "$name (versions)" "$(out versions)" '["clang-20","gcc-14"]' || return 0
  assert_eq "$name (primary)" "$(out primary-version)" "clang-20" || return 0
  assert_eq "$name (primary tag)" "$(out primary-container-tag)" "20" || return 0
  assert_eq "$name (tags)" "$(out container-tags)" '{"clang-20":"20","gcc-14":"14"}' || return 0
  assert_eq "$name (suffixes)" "$(out container-suffixes)" \
    '{"clang-20":"cpp-clang","gcc-14":"cpp-gcc"}' || return 0
  pass_case "$name"
}

# [ci].primary-version overrides the newest resolved version.
case_explicit_primary() {
  local name="explicit-primary"
  run_derive "$(toml python library 'primary-version = "3.14"')"
  assert_ok "$name" || return 0
  assert_eq "$name (primary)" "$(out primary-version)" "3.14" || return 0
  assert_eq "$name (primary tag)" "$(out primary-container-tag)" "3.14" || return 0
  pass_case "$name"
}

# A repo with no language builds the base image at latest.
case_no_language() {
  local name="no-language-latest"
  run_derive "$(toml '' library 'versions = ["latest"]')"
  assert_ok "$name" || return 0
  assert_eq "$name (versions)" "$(out versions)" '["latest"]' || return 0
  assert_eq "$name (primary tag)" "$(out primary-container-tag)" "latest" || return 0
  assert_eq "$name (suffixes)" "$(out container-suffixes)" '{"latest":"base"}' || return 0
  pass_case "$name"
}

# The action's `version-window` input (VERSION_WINDOW) reaches the resolver as
# VRG_VERSION_WINDOW.
case_version_window_input() {
  local name="version-window-input"
  run_derive "$(toml go library '')" --input-window
  assert_ok "$name" || return 0
  assert_eq "$name (versions)" "$(out versions)" '["1.26","1.25"]' || return 0
  pass_case "$name"
}

# A resolver warning (an app pinning two versions) stays visible as a
# ::warning:: annotation and does not fail the step.
case_warning_annotation() {
  local name="warning-annotation"
  run_derive "$(toml python application 'versions = ["3.14", "3.13"]')"
  assert_ok "$name" || return 0
  case "$stderr" in
    *"::warning::"*"builds exactly one version"*) ;;
    *)
      fail_case "$name" "expected a ::warning:: annotation, got '$stderr'"
      return
      ;;
  esac
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# derive_fails_on_resolver_error: a pin outside the window fails the step with
# the resolver's message as ::error::, and no outputs are written.
# ---------------------------------------------------------------------------
case_resolver_error() {
  local name="derive_fails_on_resolver_error"
  run_derive "$(toml python library 'versions = ["3.12"]')"
  assert_error "$name" "pins 3.12, which is not in the python window" || return 0
  pass_case "$name"
}

case_missing_file() {
  local name="missing-vergil-toml"
  run_derive __NO_FILE__
  assert_error "$name" "vergil.toml" || return 0
  pass_case "$name"
}

case_invalid_window() {
  local name="invalid-window-override"
  run_derive "$(toml python library '')" VRG_VERSION_WINDOW=/nonexistent/window.json
  assert_error "$name" "cannot read the version window" || return 0
  pass_case "$name"
}

case_resolver_missing() {
  local name="resolver-not-on-path" bin tool
  # A PATH holding only what derive.sh needs besides the resolver.
  bin="$(mktemp -d)"
  for tool in bash jq mktemp rm; do
    ln -s "$(command -v "$tool")" "${bin}/${tool}"
  done
  run_derive "$(toml python library '')" PATH="$bin"
  rm -rf "$bin"
  assert_error "$name" "vrg-ci-resolve is not on PATH" || return 0
  pass_case "$name"
}

case_library_window
case_matches_github_output
case_app_newest
case_packaged_app
case_cpp_tags
case_explicit_primary
case_no_language
case_version_window_input
case_warning_annotation
case_resolver_error
case_missing_file
case_invalid_window
case_resolver_missing

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
