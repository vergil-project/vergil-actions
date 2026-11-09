#!/usr/bin/env bash
#
# Check a managed package toolchain image against its marker file (epic
# vergil-project/.github#607, issue vergil-project/vergil-actions#1088).
#
# A toolchain image built by vergil-containers (prod-pkg-ubuntu, prod-pkg-rhel)
# ships its toolchain preinstalled and writes /etc/vergil/package-toolchain.
# The package setup action skips its own installs when that marker exists and
# runs this script instead, so an image whose marker lies fails the job here
# rather than falling through to a raw-image install.
#
# The marker contract (the images write it; this script reads it):
#   - one "<tool> <version>" line per tool, separated by a single space;
#   - <tool> is a command name, looked up on PATH;
#   - <version> is the first [0-9]+(\.[0-9]+)+ token of `<tool> --version`'s
#     standard output;
#   - it always lists uv, nfpm, curl, git, gpg, tar and gzip.
# Blank lines are ignored; anything else that is not a well-formed line is an
# error, as is a marker with no tool lines at all.
#
# Usage: check-toolchain.sh [--nfpm]
#   --nfpm  the job needs nFPM (build cells): fail unless the marker lists it.
#
# Exits 0 when every listed tool is on PATH at its listed version (and nfpm is
# listed, with --nfpm). Otherwise prints one ::error:: line per problem, after
# checking everything, and exits 1.
#
# The script uses only bash builtins, so it runs before any tool is trusted.
# Test seam: VRG_TOOLCHAIN_MARKER (default /etc/vergil/package-toolchain).
set -euo pipefail

marker="${VRG_TOOLCHAIN_MARKER:-/etc/vergil/package-toolchain}"
version_re='[0-9]+(\.[0-9]+)+'

need_nfpm=false
for arg in "$@"; do
  case "$arg" in
    --nfpm) need_nfpm=true ;;
    *)
      echo "::error::check-toolchain.sh: unknown argument '${arg}' (usage: check-toolchain.sh [--nfpm])" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$marker" ]; then
  echo "::error::toolchain marker ${marker} not found" >&2
  exit 1
fi

errors=0
error() {
  echo "::error::$*" >&2
  errors=$((errors + 1))
}

declare -A listed=()
lineno=0
entries=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  [ -z "$line" ] && continue
  if [[ ! "$line" =~ ^([A-Za-z0-9._+-]+)\ (${version_re})$ ]]; then
    error "toolchain marker ${marker} line ${lineno} is not '<tool> <version>': '${line}'"
    continue
  fi
  tool="${BASH_REMATCH[1]}"
  want="${BASH_REMATCH[2]}"
  if [ -n "${listed[$tool]+set}" ]; then
    error "toolchain marker ${marker} line ${lineno} lists ${tool} again"
    continue
  fi
  listed[$tool]="$want"
  entries=$((entries + 1))

  if ! command -v "$tool" >/dev/null 2>&1; then
    error "toolchain marker lists ${tool} ${want}, but ${tool} is not on PATH"
    continue
  fi
  rc=0
  output="$("$tool" --version 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    error "toolchain marker lists ${tool} ${want}, but '${tool} --version' exited ${rc}"
    continue
  fi
  if [[ ! "$output" =~ $version_re ]]; then
    error "toolchain marker lists ${tool} ${want}, but '${tool} --version' printed no version"
    continue
  fi
  have="${BASH_REMATCH[0]}"
  if [ "$have" != "$want" ]; then
    error "toolchain marker lists ${tool} ${want}, but ${tool} on PATH is ${have}"
    continue
  fi
  echo "${tool} ${have}: ok"
done <"$marker"

if [ "$entries" -eq 0 ] && [ "$errors" -eq 0 ]; then
  error "toolchain marker ${marker} is empty: a toolchain image must list its tools"
fi

if [ "$need_nfpm" = true ] && [ -z "${listed[nfpm]+set}" ]; then
  error "nfpm is required (nfpm: \"true\"), but toolchain marker ${marker} does not list nfpm"
fi

if [ "$errors" -ne 0 ]; then
  exit 1
fi
echo "Toolchain matches ${marker}."
