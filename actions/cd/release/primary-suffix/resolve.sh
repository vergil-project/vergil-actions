#!/usr/bin/env bash
#
# Pick the cd-release `release` job's image suffix from the resolver's answer
# (issue #1020, epic vergil-project/.github#407).
#
# The suffix is the primary version's entry in `container-suffixes`, both from
# `vrg-ci-resolve` by way of the shared setup action. With the resolver's
# primary-container-tag, the release image is
#
#   ghcr.io/vergil-project/<prefix>-<container-suffixes[primary]>:<primary-container-tag>
#
# which is the image CI's primary leg runs on (clang-20 -> prod-cpp-clang:20,
# not the unpublished prod-cpp:20 that `language: cpp` used to name).
#
# The caller's `container-suffix` (SUFFIX) is a cross-check, not an input to the
# image, as in actions/ci/matrix: when it is set it must equal the resolved
# primary suffix. A mismatch means the caller's cd.yml and the repo's
# vergil.toml disagree on the language or the primary version, and releasing
# from the wrong image could build and publish the wrong thing, so it fails
# loudly instead.
#
# The logic lives here (not inline in action.yml) so it is unit-testable
# (actions/cd/release/tests/container-tag.test.sh runs it on fixture repos).
#
# Inputs (env): PRIMARY, CONTAINER_SUFFIXES (JSON object keyed by version),
# SUFFIX (optional).
# Output ($GITHUB_OUTPUT): primary-container-suffix.
set -euo pipefail

error() {
  echo "::error::cd/release/primary-suffix: $*" >&2
  exit 1
}

for name in PRIMARY CONTAINER_SUFFIXES; do
  if [ -z "${!name:-}" ]; then
    error "${name} is empty; pass the shared setup action's outputs" \
      "(primary-version, container-suffixes) to this action"
  fi
done

if ! jq -en --argjson s "$CONTAINER_SUFFIXES" '$s | type == "object"' >/dev/null 2>&1; then
  error "container-suffixes must be a JSON object (got '${CONTAINER_SUFFIXES}')"
fi

suffix="$(jq -rn --argjson s "$CONTAINER_SUFFIXES" --arg p "$PRIMARY" \
  'if ($s[$p] | type) == "string" and ($s[$p] | length) > 0 then $s[$p] else "" end')"
if [ -z "$suffix" ]; then
  error "container-suffixes has no suffix for the primary version '${PRIMARY}'" \
    "(got ${CONTAINER_SUFFIXES})"
fi

if [ -n "${SUFFIX:-}" ] && [ "$SUFFIX" != "$suffix" ]; then
  error "the caller's container-suffix '${SUFFIX}' does not match the image" \
    "suffix the resolver chose for this repo's primary version '${PRIMARY}'" \
    "('${suffix}'). The calling cd.yml and vergil.toml" \
    "([project].primary-language, [ci]) disagree; fix whichever is wrong," \
    "or drop container-suffix from cd.yml"
fi

echo "primary-container-suffix=${suffix}" >>"$GITHUB_OUTPUT"
echo "Release image suffix: ${suffix} (primary version ${PRIMARY})"
