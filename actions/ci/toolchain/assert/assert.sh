#!/usr/bin/env bash
#
# Assert that the interpreter or toolchain actually running a CI leg is the
# version CI resolved for it (epic vergil-project/.github#407, spec §6.5,
# requirement 3).
#
# A repo's own files can pick the interpreter behind Vergil's back (for Python,
# `.python-version` or uv's `python-preference`), and a leg would then pass on a
# version it never ran. This is the backstop: it asks the toolchain what it is
# and fails the leg when that is not the resolved `x.y`.
#
#   python — `uv run --frozen python -c ...`, the interpreter uv gives the
#            project, which is the one the leg's tests run on. The workflow sets
#            UV_PYTHON to the leg's version before this runs. `--frozen` keeps
#            uv from rewriting uv.lock.
#   go     — `go env GOVERSION` (go1.26.3 -> 1.26). Run in the module, so a
#            `toolchain` switch in go.mod is what gets reported.
#   other  — no assertion yet (each language's turn adds one); a notice says so.
#
# On a mismatch it prints `::error::CI resolved <expected> but the job runs
# <actual>` and exits 1. Any failure to ask the toolchain is also an error.
#
# Inputs (env): LANGUAGE, EXPECTED (the leg's resolved version, x.y).
set -euo pipefail

language="${LANGUAGE:-}"
expected="${EXPECTED:-}"

error() {
  echo "::error::$*" >&2
  exit 1
}

# x_y <version text> — the x.y of the first x.y[.z] in the text, or nothing.
x_y() {
  local re='([0-9]+)\.([0-9]+)'
  if [[ "$1" =~ $re ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

check_expected() {
  if ! [[ "$expected" =~ ^[0-9]+\.[0-9]+$ ]]; then
    error "assert-toolchain: expected must be an x.y version for ${language}" \
      "(got '${expected}')"
  fi
}

case "$language" in
  python)
    check_expected
    err_file="$(mktemp)"
    trap 'rm -f "$err_file"' EXIT
    rc=0
    actual="$(uv run --frozen python -c \
      'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' \
      2>"$err_file")" || rc=$?
    # uv reports its own progress on stderr; show it, it says which
    # interpreter uv chose and why.
    cat "$err_file" >&2
    if [ "$rc" -ne 0 ]; then
      error "assert-toolchain: cannot ask uv for the job's Python interpreter" \
        "(uv run exited ${rc}): $(tr '\n' ' ' <"$err_file")"
    fi
    if ! [[ "$actual" =~ ^[0-9]+\.[0-9]+$ ]]; then
      error "assert-toolchain: unexpected answer from the job's Python interpreter: '${actual}'"
    fi
    ;;
  go)
    check_expected
    raw="$(go env GOVERSION 2>&1)" \
      || error "assert-toolchain: cannot ask go for its version: ${raw}"
    actual="$(x_y "$raw")"
    if [ -z "$actual" ]; then
      error "assert-toolchain: go env GOVERSION gave '${raw}', which has no x.y version"
    fi
    ;;
  *)
    echo "::notice::assert-toolchain: no toolchain assertion for language" \
      "'${language}' yet; only python and go are checked"
    exit 0
    ;;
esac

if [ "$actual" != "$expected" ]; then
  error "CI resolved ${expected} but the job runs ${actual}"
fi
echo "assert-toolchain: ${language} ${actual} matches the resolved version ${expected}"
