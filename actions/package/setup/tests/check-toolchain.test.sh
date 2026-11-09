#!/usr/bin/env bash
#
# Behavioural test for check-toolchain.sh — the package setup action's check
# of a managed package toolchain image against its marker file
# (/etc/vergil/package-toolchain; epic vergil-project/.github#607).
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash check-toolchain.test.sh`. It needs no root and touches
# no real /etc: each case writes a fixture marker (VRG_TOOLCHAIN_MARKER) and
# puts `<tool> --version` stubs in a stub dir that is the whole PATH, so the
# host's real tools can never satisfy the check.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../check-toolchain.sh"

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

# make_env — echoes a fresh temp dir holding bin/ (the stub PATH) and an empty
# marker file.
make_env() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/bin"
  : >"${dir}/marker"
  printf '%s' "$dir"
}

# stub <env dir> <tool> <version output> — a tool whose --version prints the
# given text.
stub() {
  printf '#!%s\nprintf "%%s\\n" %q\n' "$BASH" "$3" >"${1}/bin/${2}"
  chmod +x "${1}/bin/${2}"
}

# run_check <env dir> [args...] — runs check-toolchain.sh; sets rc, out, err.
run_check() {
  local dir="$1"
  shift
  rc=0
  env PATH="${dir}/bin" VRG_TOOLCHAIN_MARKER="${dir}/marker" \
    "$BASH" "$script" "$@" >"${dir}/out" 2>"${dir}/err" || rc=$?
  out="$(cat "${dir}/out")"
  err="$(cat "${dir}/err")"
}

# expect <name> <expected rc> [substring...] — asserts the exit code, and that
# each substring appears in stderr on a line starting with ::error::.
expect() {
  local name="$1" want="$2" s
  shift 2
  if [ "$rc" -ne "$want" ]; then
    fail_case "$name" "expected exit ${want}, got ${rc}; stdout: ${out}; stderr: ${err}"
    return 1
  fi
  for s in "$@"; do
    if ! printf '%s\n' "$err" | grep -F -- "$s" | grep -q '^::error::'; then
      fail_case "$name" "stderr has no ::error:: line containing '${s}'; stderr: ${err}"
      return 1
    fi
  done
  return 0
}

# expect_no_errors <name> — a passing run prints no ::error:: line.
expect_no_errors() {
  if printf '%s\n' "$err" "$out" | grep -q '::error::'; then
    fail_case "$1" "a passing run printed ::error::; stdout: ${out}; stderr: ${err}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Every listed tool present at its listed version -> exit 0, with or without
# --nfpm.
# ---------------------------------------------------------------------------
case_all_present_matching() {
  local name="all_present_matching" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\nnfpm 2.48.0\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23 (x86_64-unknown-linux-gnu)"
  stub "$dir" nfpm "nfpm version 2.48.0"
  run_check "$dir" --nfpm
  if expect "$name" 0 && expect_no_errors "$name"; then
    run_check "$dir"
    expect "$name (no --nfpm)" 0 && expect_no_errors "$name" && pass_case "$name"
  fi
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# The full contract list, with real-world --version output shapes: the version
# is the first dotted-number token, not the first word, and later tokens
# (libcurl/8.5.0, gpg's libgcrypt) are ignored.
# ---------------------------------------------------------------------------
case_real_version_shapes() {
  local name="real_version_shapes" dir
  dir="$(make_env)"
  printf '%s\n' 'uv 0.12.23' 'nfpm 2.47.0' 'curl 8.5.0' 'git 2.43.0' \
    'gpg 2.4.4' 'tar 1.35' 'gzip 1.12' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23"
  stub "$dir" nfpm "  nfpm: version 2.47.0"
  stub "$dir" curl "curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13"
  stub "$dir" git "git version 2.43.0"
  stub "$dir" gpg "gpg (GnuPG) 2.4.4
libgcrypt 1.10.3"
  stub "$dir" tar "tar (GNU tar) 1.35"
  stub "$dir" gzip "gzip 1.12"
  run_check "$dir" --nfpm
  expect "$name" 0 && expect_no_errors "$name" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# A listed tool that is not on PATH -> exit 1, ::error:: naming it.
# ---------------------------------------------------------------------------
case_missing_tool() {
  local name="missing_tool" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\nnfpm 2.48.0\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23"
  run_check "$dir"
  expect "$name" 1 "nfpm" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# A listed tool at another version -> exit 1, ::error:: naming both versions.
# ---------------------------------------------------------------------------
case_version_mismatch() {
  local name="version_mismatch" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.24"
  run_check "$dir"
  expect "$name" 1 "uv" "0.12.23" "0.12.24" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# --nfpm with a marker that does not list nfpm -> exit 1, even when an nfpm
# happens to be on PATH: an image that does not claim nFPM is not a build image.
# ---------------------------------------------------------------------------
case_nfpm_required_not_listed() {
  local name="nfpm_required_not_listed" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23"
  stub "$dir" nfpm "nfpm version 2.48.0"
  run_check "$dir" --nfpm
  expect "$name" 1 "nfpm" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# No --nfpm and a marker without nfpm -> exit 0 (install-test cells).
# ---------------------------------------------------------------------------
case_no_nfpm_flag_ignores_absence() {
  local name="no_nfpm_flag_ignores_absence" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23"
  run_check "$dir"
  expect "$name" 0 && expect_no_errors "$name" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# An empty marker (zero tool lines, blank lines only) -> exit 1: an empty
# marker is a broken image, never a pass.
# ---------------------------------------------------------------------------
case_empty_marker() {
  local name="empty_marker" dir
  dir="$(make_env)"
  run_check "$dir"
  expect "$name" 1 "empty" || {
    rm -rf "$dir"
    return
  }
  printf '\n\n' >"${dir}/marker"
  run_check "$dir"
  expect "$name (blank lines)" 1 "empty" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Every problem is reported before exiting: two broken tools -> two ::error::
# lines.
# ---------------------------------------------------------------------------
case_reports_every_problem() {
  local name="reports_every_problem" dir count
  dir="$(make_env)"
  printf 'uv 0.12.23\nnfpm 2.48.0\ngit 2.43.0\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.24"
  stub "$dir" git "git version 2.43.0"
  run_check "$dir"
  if expect "$name" 1 "uv" "nfpm"; then
    count="$(printf '%s\n' "$err" | grep -c '^::error::' || true)"
    if [ "$count" -eq 2 ]; then
      pass_case "$name"
    else
      fail_case "$name" "expected 2 ::error:: lines, got ${count}; stderr: ${err}"
    fi
  fi
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Malformed marker lines (wrong field count, a version that is not dotted
# numbers) and a duplicated tool -> exit 1, each reported.
# ---------------------------------------------------------------------------
case_malformed_marker() {
  local name="malformed_marker" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\nnfpm\ngit latest\ntar 1.35 extra\nuv 0.12.23\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23"
  stub "$dir" git "git version 2.43.0"
  stub "$dir" tar "tar (GNU tar) 1.35"
  run_check "$dir"
  expect "$name" 1 "line 2" "line 3" "line 4" "line 5" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# A tool whose --version prints no dotted version, or fails -> exit 1.
# ---------------------------------------------------------------------------
case_unreadable_version() {
  local name="unreadable_version" dir
  dir="$(make_env)"
  printf 'uv 0.12.23\ngit 2.43.0\n' >"${dir}/marker"
  stub "$dir" uv "uv development build"
  printf '#!%s\necho "git: broken" >&2\nexit 3\n' "$BASH" >"${dir}/bin/git"
  chmod +x "${dir}/bin/git"
  run_check "$dir"
  expect "$name" 1 "uv" "git" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# A missing marker file, or an unknown argument -> exit 1 with ::error::.
# ---------------------------------------------------------------------------
case_bad_invocation() {
  local name="bad_invocation" dir
  dir="$(make_env)"
  rm "${dir}/marker"
  run_check "$dir"
  expect "$name" 1 "marker" || {
    rm -rf "$dir"
    return
  }
  printf 'uv 0.12.23\n' >"${dir}/marker"
  stub "$dir" uv "uv 0.12.23"
  run_check "$dir" --bogus
  expect "$name (unknown argument)" 1 "--bogus" && pass_case "$name"
  rm -rf "$dir"
}

case_all_present_matching
case_real_version_shapes
case_missing_tool
case_version_mismatch
case_nfpm_required_not_listed
case_no_nfpm_flag_ignores_absence
case_empty_marker
case_reports_every_problem
case_malformed_marker
case_unreadable_version
case_bad_invocation

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
