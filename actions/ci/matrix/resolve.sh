#!/usr/bin/env bash
#
# Resolve the per-version CI job matrix for a reusable CI workflow.
#
# Emits two JSON arrays of {version, image} objects to $GITHUB_OUTPUT:
#
#   all  — one entry per configured version. Consumed by per-version kinds
#          (TEST always; TYPECHECK for languages whose typecheck is per-version,
#          e.g. C++).
#   once — the matrix collapsed to the primary (first) version for languages
#          that carry run-once kinds (C++, TypeScript), else identical to `all`.
#          Consumed by run-once kinds (LINT, AUDIT; and TYPECHECK for
#          TypeScript). This mirrors github_config.desired_ci_gates_ruleset,
#          which keys a run-once kind's single gate to ci.versions[0].
#
# Image routing by language:
#
#   cpp         — the compiler family rides the version token (`clang-20`,
#                 `gcc-14`): split into family + numeric tag →
#                 `<prefix>-cpp-<family>:<tag>` (epic vergil-project/.github#207
#                 §6). e.g. clang-20 -> prod-cpp-clang:20.
#   typescript  — the Node major rides the version token (`node-24`): the
#                 `ts-node` runtime family rides the image *suffix* and the
#                 numeric part is the tag → `<prefix>-<suffix>:<tag>` (epic
#                 vergil-project/.github#284). e.g. node-24 (suffix ts-node) ->
#                 prod-ts-node:24. This matches repo_init's _container_suffix
#                 (`ts-node`) / _container_tag (the Node major) on the tooling
#                 side.
#   everything  — the single-suffix scheme `<prefix>-<suffix>:<version>`, with
#   else          the language name used as the suffix when none is given.
#
# The logic lives here (not inline in action.yml) so it is unit-testable
# (tests/resolve.test.sh).
#
# Inputs (env): LANGUAGE, VERSIONS (JSON array string), PREFIX, SUFFIX.
set -euo pipefail

registry="ghcr.io/vergil-project"
prefix="${PREFIX:-prod}"

all=$(jq -cn \
  --argjson versions "$VERSIONS" \
  --arg lang "$LANGUAGE" \
  --arg prefix "$prefix" \
  --arg suffix "$SUFFIX" \
  --arg reg "$registry" '
  $versions | map(
    if $lang == "cpp" then
      (. | split("-")) as $p
      | { version: .,
          image: ($reg + "/" + $prefix + "-cpp-" + $p[0]
                  + ":" + ($p[1:] | join("-"))) }
    elif $lang == "typescript" then
      # The Node major rides the tag; the `ts-node` family rides the suffix.
      # node-24 (suffix ts-node) -> prod-ts-node:24. Fall back to `ts-<family>`
      # when no suffix is supplied so the runtime family is still explicit.
      (. | split("-")) as $p
      | (if $suffix == "" then ("ts-" + $p[0]) else $suffix end) as $sfx
      | { version: .,
          image: ($reg + "/" + $prefix + "-" + $sfx
                  + ":" + ($p[1:] | join("-"))) }
    else
      (if $suffix == "" then $lang else $suffix end) as $sfx
      | { version: ., image: ($reg + "/" + $prefix + "-" + $sfx + ":" + .) }
    end)')

# Run-once kinds collapse to the primary (first) version for matrix languages
# that declare them (C++, TypeScript), so LINT/AUDIT (and TypeScript's TYPECHECK)
# emit a single job/gate instead of one per version — matching the run-once
# gates github_config.desired_ci_gates_ruleset keys to ci.versions[0]. Every
# other language keeps `once` == `all`, so its gates are byte-identical to the
# pre-cardinality behavior.
case "$LANGUAGE" in
  cpp | typescript) once=$(printf '%s' "$all" | jq -c '.[:1]') ;;
  *) once="$all" ;;
esac

{
  echo "all=$all"
  echo "once=$once"
} >> "$GITHUB_OUTPUT"

echo "Resolved matrix (all): $all"
echo "Resolved matrix (once): $once"
