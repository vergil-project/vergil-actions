#!/usr/bin/env bash
#
# Build the per-version CI job matrix for a reusable CI workflow from the
# resolver's answer.
#
# The versions, and the image suffix and tag of each, come from `vrg-ci-resolve`
# by way of the shared setup action's outputs (`versions`, `primary-version`,
# `container-tags`, `container-suffixes`; epic vergil-project/.github#407). This
# script does no version or family routing of its own: every image is
#
#   ghcr.io/vergil-project/<prefix>-<container-suffixes[v]>:<container-tags[v]>
#
# so clang-20 -> prod-cpp-clang:20, node-24 -> prod-ts-node:24 and
# 3.14 -> prod-python:3.14, exactly as the resolver says.
#
# Emits two JSON arrays of {version, image} objects to $GITHUB_OUTPUT:
#
#   all  — one entry per resolved version. Consumed by per-version kinds (TEST
#          always; TYPECHECK for languages whose typecheck is per-version).
#   once — the primary version's entry alone for the languages that carry
#          run-once kinds (C++, TypeScript), else identical to `all`. Consumed
#          by run-once kinds (LINT, AUDIT; and TYPECHECK for TypeScript).
#
# The caller's `container-suffix` (SUFFIX) is a cross-check, not an input to the
# image: when it is set it must be one of the resolved suffixes. A mismatch
# means the caller's workflow and the repo's vergil.toml disagree on the
# language (for example `container-suffix: python` with no
# [project].primary-language, which resolves to the base image at latest), and
# running the legs on the wrong image could pass without testing anything, so
# it fails loudly instead.
#
# The logic lives here (not inline in action.yml) so it is unit-testable
# (tests/resolve.test.sh).
#
# Inputs (env): LANGUAGE, VERSIONS (JSON array), PRIMARY, CONTAINER_TAGS and
# CONTAINER_SUFFIXES (JSON objects keyed by version), PREFIX, SUFFIX.
set -euo pipefail

registry="ghcr.io/vergil-project"
prefix="${PREFIX:-prod}"

error() {
  echo "::error::ci/matrix: $*" >&2
  exit 1
}

for name in VERSIONS PRIMARY CONTAINER_TAGS CONTAINER_SUFFIXES; do
  if [ -z "${!name:-}" ]; then
    error "${name} is empty; pass the shared setup action's outputs (versions," \
      "primary-version, container-tags, container-suffixes) to this action"
  fi
done

# Check the shape of the resolver's answer before building anything from it: a
# missing tag or suffix must fail here, not become an image named ':null'.
problem="$(jq -rn \
  --argjson versions "$VERSIONS" \
  --argjson tags "$CONTAINER_TAGS" \
  --argjson suffixes "$CONTAINER_SUFFIXES" \
  --arg primary "$PRIMARY" '
  if ($versions | type) != "array" or ($versions | length) == 0
    then "versions must be a non-empty JSON array (got \($versions | tojson))"
  elif ($tags | type) != "object" then "container-tags must be a JSON object"
  elif ($suffixes | type) != "object" then "container-suffixes must be a JSON object"
  else
    ([$versions[] | select(($tags[.] | type) != "string")] ) as $no_tag
    | ([$versions[] | select(($suffixes[.] | type) != "string")]) as $no_suffix
    | if ($no_tag | length) > 0
        then "container-tags has no tag for \($no_tag | join(", "))"
      elif ($no_suffix | length) > 0
        then "container-suffixes has no suffix for \($no_suffix | join(", "))"
      elif ($versions | index($primary)) == null
        then "primary-version \($primary) is not one of the versions \($versions | join(", "))"
      else "" end
  end')" || error "cannot parse the resolver outputs passed to this action"
if [ -n "$problem" ]; then
  error "$problem"
fi

if [ -n "${SUFFIX:-}" ]; then
  resolved_suffixes="$(jq -rn --argjson s "$CONTAINER_SUFFIXES" '[$s[]] | unique | join(", ")')"
  if ! jq -en --argjson s "$CONTAINER_SUFFIXES" --arg want "$SUFFIX" \
    '[$s[]] | index($want) != null' >/dev/null; then
    error "the caller's container-suffix '${SUFFIX}' is not an image suffix the" \
      "resolver chose for this repo (${resolved_suffixes}). The workflow's" \
      "language inputs and vergil.toml ([project].primary-language, [ci]) disagree;" \
      "fix whichever is wrong"
  fi
fi

all="$(jq -cn \
  --argjson versions "$VERSIONS" \
  --argjson tags "$CONTAINER_TAGS" \
  --argjson suffixes "$CONTAINER_SUFFIXES" \
  --arg prefix "$prefix" \
  --arg reg "$registry" '
  $versions | map({
    version: .,
    image: ($reg + "/" + $prefix + "-" + $suffixes[.] + ":" + $tags[.])
  })')"

# Run-once kinds run on the primary version for the matrix languages that
# declare them (C++, TypeScript), so LINT/AUDIT (and TypeScript's TYPECHECK)
# emit a single job instead of one per version. Every other language keeps
# `once` == `all`.
case "${LANGUAGE:-}" in
  cpp | typescript)
    once="$(printf '%s' "$all" | jq -c --arg primary "$PRIMARY" \
      'map(select(.version == $primary))')"
    ;;
  *) once="$all" ;;
esac

{
  echo "all=$all"
  echo "once=$once"
} >>"$GITHUB_OUTPUT"

echo "Resolved matrix (all): $all"
echo "Resolved matrix (once): $once"
