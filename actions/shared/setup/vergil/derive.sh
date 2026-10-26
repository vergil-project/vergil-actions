#!/usr/bin/env bash
#
# Derive the CI version set for a reusable CI workflow by calling the single
# resolver, `vrg-ci-resolve` (vergil-tooling; epic vergil-project/.github#407,
# spec §6.3).
#
# Resolution is NOT implemented here. The resolver reads vergil.toml and the
# published language version window (vergil-containers'
# docker/versions/window.json at the [dependencies].vergil ref) and applies
# every rule: library vs. app by [project].repository-type, pins checked
# against the window, the [ci].primary-version override, the packaged-Python
# runtime rule, and the image suffix and tag of every version. This script only
# runs it once and copies its answer into $GITHUB_OUTPUT:
#
#   versions              — the resolved versions, newest first, as a compact
#                           JSON array string. The `matrix` job fans out over it.
#   primary-version       — the primary version (the newest resolved version,
#                           or [ci].primary-version). Single-container jobs and
#                           run-once kinds run on it.
#   primary-container-tag — the image tag of the primary version (clang-20 -> 20,
#                           3.14 -> 3.14). The single-container `common` and
#                           `custom` (ci-quality) and `version-bump`
#                           (ci-version-bump) jobs use it as their image tag.
#   container-tags        — compact JSON object, version token -> image tag.
#   container-suffixes    — compact JSON object, version token -> image suffix
#                           (clang-20 -> cpp-clang, 3.14 -> python).
#
# The first three are what `vrg-ci-resolve --format github-output` prints. The
# matrix also needs the last two, which only `--format json` carries, so this
# script runs `--format json` once and renders all five from that single
# answer: one window fetch, and no chance of two outputs disagreeing.
#
# Failure is loud and final. A resolver error (window fetch, invalid window, a
# pin outside the window, an app that pins more than one version, a C++ or
# TypeScript repo with no pin, an invalid primary-version, a missing or invalid
# vergil.toml) fails the step with the resolver's message as `::error::`
# annotations and writes no outputs. There is no fallback derivation.
#
# Inputs (env):
#   VERGIL_CONFIG_DIR — directory holding vergil.toml (default: the current
#                       directory). The test harness points it at fixtures.
#   VERSION_WINDOW    — the setup action's optional `version-window` input.
#                       When non-empty it is exported as VRG_VERSION_WINDOW, the
#                       resolver's one sanctioned override (a local
#                       window.json path, for tests). When empty, any
#                       VRG_VERSION_WINDOW already in the environment is left as
#                       it is.
set -euo pipefail

config_dir="${VERGIL_CONFIG_DIR:-.}"

if [ -n "${VERSION_WINDOW:-}" ]; then
  export VRG_VERSION_WINDOW="$VERSION_WINDOW"
fi

if ! command -v vrg-ci-resolve >/dev/null 2>&1; then
  echo "::error::vrg-ci-resolve is not on PATH. It ships with vergil-tooling" \
    "v2.1.253 and later; the install step above should have put it there." \
    "Check that [dependencies].vergil in vergil.toml names a vergil-tooling" \
    "release that includes it" >&2
  exit 1
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

rc=0
resolution="$(vrg-ci-resolve --format json --repo-root "$config_dir" 2>"$err_file")" || rc=$?

if [ "$rc" -ne 0 ]; then
  # Surface every line the resolver printed as an error annotation, so the
  # reason is on the run summary, not only in the step log.
  printed=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    echo "::error::${line}" >&2
    printed=1
  done <"$err_file"
  if [ "$printed" -eq 0 ]; then
    echo "::error::vrg-ci-resolve exited ${rc} without a message" >&2
  fi
  exit "$rc"
fi

# A successful run may still print `warning: ` lines on stderr. The resolver
# emits none today (an app that pins more than one version is now an error,
# not a warning), but keep any warning visible as a warning annotation and pass
# any other line through unchanged.
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  case "$line" in
    "warning: "*) echo "::warning::${line#warning: }" >&2 ;;
    *) echo "$line" >&2 ;;
  esac
done <"$err_file"

# Render the outputs. Every key must be present with the expected type; a
# resolver answer that lacks one is an error, never an empty output.
outputs="$(printf '%s' "$resolution" | jq -r '
  def req(k; t):
    if has(k) and (.[k] | type) == t then .[k]
    else error("vrg-ci-resolve output has no \(t) \"\(k)\"") end;
  "versions=" + (req("versions"; "array") | tojson),
  "primary-version=" + req("primary-version"; "string"),
  "primary-container-tag=" + req("primary-container-tag"; "string"),
  "container-tags=" + (req("container-tags"; "object") | tojson),
  "container-suffixes=" + (req("container-suffixes"; "object") | tojson)
' 2>&1)" || {
  echo "::error::cannot read the vrg-ci-resolve answer: ${outputs}" >&2
  exit 1
}

printf '%s\n' "$outputs" >>"$GITHUB_OUTPUT"
printf 'Resolved by vrg-ci-resolve:\n%s\n' "$outputs"
