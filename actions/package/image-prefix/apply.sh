#!/usr/bin/env bash
#
# Apply a reusable workflow's `container-prefix` to the `vrg-package matrix`
# outputs (vergil-project/vergil-actions#1132 and #1134). Used by the matrix
# jobs of ci-package.yml (`matrix`) and cd-release.yml (`package-matrix`),
# through actions/package/image-prefix.
#
# `vrg-package matrix` names every cell's image
# `ghcr.io/vergil-project/prod-pkg-<distro>:<version>`. Only that
# `ghcr.io/vergil-project/prod-pkg-` start of a cell's `image` changes, to
# `ghcr.io/vergil-project/<prefix>-pkg-`; with the default `prod` (which an
# empty value also means) each output is passed on byte for byte. A cell whose
# image is not under `prod-pkg-` keeps it, with a warning. Any other prefix, or
# a missing or malformed output, fails. Both outputs are checked and rewritten
# before either is written, so a bad one leaves no half-set outputs behind.
# The log lists the image each cell will use.
#
# The logic lives here (not inline in action.yml) so it is unit-testable
# (actions/cd/release/tests/package-image-prefix.test.sh runs it on fixture
# outputs).
#
# Inputs (env): PREFIX (optional; empty means prod), BUILD and TEST (the
# matrix's `build` and `test` outputs: one-line JSON arrays of cells, each
# with a string `image`; a repo without [package] has `[]`).
# Output ($GITHUB_OUTPUT): build, test.
set -euo pipefail

# An empty input means the default, as `inputs.container-prefix || 'prod'`
# does in the reusable workflows' `container:` lines.
prefix="${PREFIX:-prod}"
case "$prefix" in
  prod|dev) ;;
  *)
    echo "::error::invalid container-prefix input '${prefix}' (expected prod or dev)"
    exit 1
    ;;
esac
from="ghcr.io/vergil-project/prod-pkg-"
to="ghcr.io/vergil-project/${prefix}-pkg-"
echo "container prefix: ${prefix}"
lines=()
for pair in build:BUILD test:TEST; do
  key="${pair%%:*}"
  var="${pair#*:}"
  value="${!var:-}"
  if [ -z "$value" ]; then
    echo "::error::vrg-package matrix wrote no '${key}' output"
    exit 1
  fi
  if [[ "$value" == *$'\n'* ]] ||
    ! printf '%s' "$value" | jq -e \
      'type == "array" and all(.[]; type == "object" and (.image | type) == "string")' \
      >/dev/null 2>&1; then
    echo "::error::vrg-package matrix's '${key}' output is not a one-line JSON array of cells with a string image"
    exit 1
  fi
  if [ "$prefix" = prod ]; then
    out="$value"
  else
    out="$(printf '%s' "$value" | jq -c --arg from "$from" --arg to "$to" \
      'map(if (.image | startswith($from)) then .image = $to + (.image | ltrimstr($from)) else . end)')"
  fi
  cells="$(printf '%s' "$out" | jq -r '.[] | [(.id // "(no id)" | tostring), .image] | @tsv')"
  if [ -n "$cells" ]; then
    while IFS=$'\t' read -r id image; do
      echo "${key} / ${id}: ${image}"
      if [[ "$image" != "$to"* ]]; then
        echo "::warning::${key} / ${id}: image '${image}' is not under '${from}', so container-prefix '${prefix}' leaves it unchanged"
      fi
    done < <(printf '%s\n' "$cells")
  fi
  lines+=("${key}=${out}")
done
printf '%s\n' "${lines[@]}" >> "$GITHUB_OUTPUT"
