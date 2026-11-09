#!/usr/bin/env bash
#
# Behavioural test for detect.sh — the package setup action's vergil-tooling
# install-spec resolver.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash detect.test.sh`. It needs uv on PATH: the cases for
# the repo's uv settings (issue #1003) test detect.sh's uv path and fail
# without it. They may download a managed Python 3.15 into a temp dir when no
# system 3.15 is on PATH, as in the package images.
#
# Each case writes fixture pyproject.toml / vergil.toml files into a temp dir,
# runs detect.sh against it, and asserts the printed spec (or the failure).
#
# detect.sh takes the driver Python from VRG_DRIVER_PYTHON, which the action
# sets from its `python` input. The harness exports it for every case; the
# driver-python cases unset it or check that uv is given it.
set -euo pipefail

driver_python="3.15"
export VRG_DRIVER_PYTHON="$driver_python"

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

# ---------------------------------------------------------------------------
# Cases 6 and 7: the repo's uv settings must not change what detect.sh does
# (issue #1003). A repo may set `python-downloads = "manual"` and
# `python-preference = "only-managed"` in [tool.uv] (pyproject.toml) or in
# uv.toml. uv reads those from the working directory, so the case runs
# detect.sh from inside the fixture repo, as the setup action does
# (`detect.sh .`).
#
# UV_PYTHON_INSTALL_DIR is a fresh empty dir, so no managed Python exists:
# without --no-config, uv honours the settings and fails ("Python downloads
# are set to 'manual'"). With it, uv uses a system 3.15 if there is one, else
# downloads one, as in the package images. The uv environment variables that
# would mask or change that are unset. The case needs uv: detect.sh only reads
# uv settings on its uv path, so without uv it fails rather than pass vacuously.
# ---------------------------------------------------------------------------
# run_in_configured_repo <name> <config file name> <config body>
run_in_configured_repo() {
  local name="$1" dir pydir err out stderr rc=0
  if ! command -v uv >/dev/null 2>&1; then
    fail_case "$name" "uv is not on PATH; this case tests detect.sh's uv path"
    return
  fi
  dir="$(fixture '[project]
name = "vergil-python"' '[dependencies]
vergil = "v2.1"')"
  if [ "$2" = pyproject.toml ]; then
    printf '\n%s\n' "[tool.uv]" "$3" >>"${dir}/pyproject.toml"
  else
    printf '%s\n' "$3" >"${dir}/$2"
  fi
  pydir="$(mktemp -d)"
  err="$(mktemp)"
  out="$(cd "$dir" && env -u UV_PYTHON -u UV_PYTHON_PREFERENCE \
    -u UV_PYTHON_DOWNLOADS -u UV_NO_CONFIG -u UV_CONFIG_FILE \
    UV_PYTHON_INSTALL_DIR="$pydir" bash "$detect_sh" . 2>"$err")" || rc=$?
  stderr="$(cat "$err")"
  rm -rf "$dir" "$pydir" "$err"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "detect.sh exited ${rc}: ${stderr}"
    return
  fi
  assert_eq "$name" "$out" \
    "vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1" || return
  pass_case "$name"
}

uv_settings='python-downloads = "manual"
python-preference = "only-managed"'

case_ignores_pyproject_uv_settings() {
  run_in_configured_repo "ignores-pyproject-uv-settings" pyproject.toml "$uv_settings"
}

case_ignores_uv_toml() {
  run_in_configured_repo "ignores-uv-toml" uv.toml "$uv_settings"
}

# ---------------------------------------------------------------------------
# Case 8: VRG_DRIVER_PYTHON unset or empty is fatal; there is no default.
# ---------------------------------------------------------------------------
case_driver_python_unset_fails() {
  local name="driver_python_unset_fails" dir err out stderr rc value
  for value in unset empty; do
    dir="$(fixture '' '[dependencies]
vergil = "v2.1"')"
    err="$(mktemp)"
    rc=0
    if [ "$value" = unset ]; then
      out="$(env -u VRG_DRIVER_PYTHON bash "$detect_sh" "$dir" 2>"$err")" || rc=$?
    else
      out="$(VRG_DRIVER_PYTHON="" bash "$detect_sh" "$dir" 2>"$err")" || rc=$?
    fi
    stderr="$(cat "$err")"
    rm -rf "$dir" "$err"
    if [ "$rc" -ne 1 ]; then
      fail_case "$name" "${value}: expected exit 1, got ${rc} (stdout '${out}')"
      return
    fi
    assert_eq "$name" "$stderr" "detect.sh: VRG_DRIVER_PYTHON must be set" || return
    assert_eq "$name" "$out" "" || return
  done
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# Case 9: detect.sh asks uv for the driver Python it was given. A `uv` stub
# first on PATH records its argv and prints the ref uv would have read. The
# stub runs no Python, so the second, made-up version proves detect.sh passes
# on whatever it is given rather than a version of its own.
# ---------------------------------------------------------------------------
case_driver_python_used() {
  local name="driver_python_used" dir stubdir argv out recorded version
  for version in "$driver_python" 3.99; do
    dir="$(fixture '' '[dependencies]
vergil = "v2.1"')"
    stubdir="$(mktemp -d)"
    argv="${stubdir}/argv"
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "%s\n" "$*" >>"$(dirname "$0")/argv"' \
      'echo v2.1' >"${stubdir}/uv"
    chmod +x "${stubdir}/uv"
    out="$(PATH="${stubdir}:${PATH}" VRG_DRIVER_PYTHON="$version" \
      bash "$detect_sh" "$dir")"
    recorded="$(cat "$argv" 2>/dev/null || true)"
    rm -rf "$dir" "$stubdir"
    assert_eq "$name" "$out" \
      "vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1" || return
    case " ${recorded} " in
      *" --python ${version} "*) ;;
      *)
        fail_case "$name" "uv argv lacks '--python ${version}': '${recorded}'"
        return
        ;;
    esac
  done
  pass_case "$name"
}

case_self_repo
case_consumer_repo
case_consumer_no_pyproject
case_missing_vergil_toml
case_missing_dependency
case_ignores_pyproject_uv_settings
case_ignores_uv_toml
case_driver_python_unset_fails
case_driver_python_used

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
