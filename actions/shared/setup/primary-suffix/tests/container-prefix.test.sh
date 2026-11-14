#!/usr/bin/env bash
#
# Test that `container-prefix` is a universal tunable (issue #1134): every
# reusable workflow (`on: workflow_call`) in .github/workflows that runs a job
# in a vergil image takes the image's prefix from its own `container-prefix`
# input, so a caller can switch each workflow file between the `prod-` and
# `dev-` images on its own.
#
# Framework-free and developer-runnable: `bash container-prefix.test.sh`. CI
# runs it from .github/workflows/smoke-setup-vergil.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners) and touches no
# network.
#
# The rules, for each reusable workflow:
#   * no string in it names a `ghcr.io/vergil-project/prod-` image (comments
#     are not strings);
#   * every job `container:` (or `container.image`) is either
#     `ghcr.io/vergil-project/${{ inputs.container-prefix || 'prod' }}-...`
#     or `${{ matrix.image }}` whose matrix comes only from `needs.<job>.
#     outputs.<key>` values set by a step that runs ./actions/ci/matrix or
#     ./actions/package/image-prefix with `container-prefix: ${{
#     inputs.container-prefix }}`;
#   * every job that calls a workflow of this repo that declares
#     `container-prefix` passes `${{ inputs.container-prefix }}` on;
#   * a workflow with any such job declares the input (string, optional,
#     default prod).
# The repo's own top-level workflows (cd.yml, ci.yml, ops.yml, the smoke
# workflows) are not reusable and are not checked. Fixture workflows check
# that each rule catches what it is for.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"

if ! command -v yq >/dev/null 2>&1; then
  printf 'container-prefix.test.sh needs yq on PATH\n' >&2
  exit 1
fi

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

# shellcheck disable=SC2016 # literal GitHub Actions expressions
{
  prefixed='ghcr.io/vergil-project/${{ inputs.container-prefix || '"'prod'"' }}-'
  passed_on='${{ inputs.container-prefix }}'
  matrix_image='${{ matrix.image }}'
}

# problems <workflow file> — prints one line per broken rule; none means the
# file honours its container-prefix (or is not a reusable workflow).
problems() {
  local wf="$1" dir job image include ref mjob key value step uses with
  local callee needs_input="" refs
  dir="$(dirname "$wf")"
  if [ "$(yq -r '.on.workflow_call != null' "$wf")" != true ]; then
    return 0
  fi
  while IFS= read -r value; do
    if [ -n "$value" ]; then
      printf 'names a prod image literally: %s\n' "$value"
    fi
  done < <(yq -r '.. | select(tag == "!!str") | select(contains("ghcr.io/vergil-project/prod-"))' "$wf")
  while IFS=$'\t' read -r job image include; do
    [ -n "$job" ] || continue
    needs_input=1
    if [[ "$image" == "$prefixed"* ]]; then
      continue
    fi
    if [ "$image" != "$matrix_image" ]; then
      printf '%s: container %s does not take its prefix from container-prefix\n' "$job" "$image"
      continue
    fi
    mapfile -t refs < <(printf '%s\n' "$include" | grep -oE 'needs\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+' || true)
    if [ "${#refs[@]}" -eq 0 ]; then
      printf '%s: matrix.image matrix %s is not a needs output\n' "$job" "$include"
      continue
    fi
    for ref in "${refs[@]}"; do
      ref="${ref#needs.}"
      mjob="${ref%%.outputs.*}"
      key="${ref#*.outputs.}"
      value="$(yq -r ".jobs.\"${mjob}\".outputs.\"${key}\" // \"\"" "$wf")"
      if ! [[ "$value" =~ ^\$\{\{\ steps\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_-]+\ \}\}$ ]]; then
        printf '%s: %s.outputs.%s (%s) is not a step output\n' "$job" "$mjob" "$key" "$value"
        continue
      fi
      step="${BASH_REMATCH[1]}"
      uses="$(yq -r ".jobs.\"${mjob}\".steps[] | select(.id == \"${step}\") | .uses // \"\"" "$wf")"
      with="$(yq -r ".jobs.\"${mjob}\".steps[] | select(.id == \"${step}\") | .with.\"container-prefix\" // \"\"" "$wf")"
      case "$uses" in
        ./actions/ci/matrix | ./actions/package/image-prefix) ;;
        *)
          printf '%s: %s step %s does not apply the prefix (uses %s)\n' "$job" "$mjob" "$step" "$uses"
          continue
          ;;
      esac
      if [ "$with" != "$passed_on" ]; then
        printf '%s: %s step %s gets container-prefix %s\n' "$job" "$mjob" "$step" "$with"
      fi
    done
  done < <(yq -r '.jobs | to_entries[] | select(.value.container != null) |
    [.key,
     (if (.value.container | tag) == "!!map" then .value.container.image else .value.container end | tostring),
     (.value.strategy.matrix.include // "" | tostring)] | @tsv' "$wf")
  while IFS=$'\t' read -r job uses with; do
    [ -n "$job" ] || continue
    callee="$(printf '%s' "$uses" | sed -nE 's#^(\./|vergil-project/vergil-actions/)\.github/workflows/([^@/]+\.ya?ml)(@.*)?$#\2#p')"
    if [ -z "$callee" ] || [ ! -f "${dir}/${callee}" ]; then
      continue
    fi
    if [ "$(yq -r '.on.workflow_call.inputs."container-prefix" != null' "${dir}/${callee}")" != true ]; then
      continue
    fi
    needs_input=1
    if [ "$with" != "$passed_on" ]; then
      printf '%s: calls %s without passing container-prefix on (got %s)\n' "$job" "$callee" "$with"
    fi
  done < <(yq -r '.jobs | to_entries[] | select(.value.uses != null) |
    [.key, .value.uses, (.value.with."container-prefix" // "")] | @tsv' "$wf")
  if [ -n "$needs_input" ]; then
    local q='.on.workflow_call.inputs."container-prefix"'
    if [ "$(yq -r "${q}.type // \"\"" "$wf")" != string ] ||
      [ "$(yq -r "${q}.required // false" "$wf")" != false ] ||
      [ "$(yq -r "${q}.default // \"\"" "$wf")" != prod ]; then
      printf 'runs a vergil image but does not declare container-prefix (string, optional, default prod)\n'
    fi
  fi
}

# The real workflows: every reusable one honours its input.
case_real_workflows() {
  local wf out checked=0
  for wf in "$workflows"/*.yml; do
    [ "$(yq -r '.on.workflow_call != null' "$wf")" = true ] || continue
    checked=$((checked + 1))
    out="$(problems "$wf")"
    if [ -n "$out" ]; then
      fail_case "$(basename "$wf")-honours-container-prefix" "$out"
    else
      pass_case "$(basename "$wf")-honours-container-prefix"
    fi
  done
  if [ "$checked" -eq 0 ]; then
    fail_case "reusable-workflows-found" "no reusable workflow in ${workflows}"
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fixture <name> <yaml> — writes a fixture workflow into $work.
fixture() {
  printf '%s\n' "$2" >"${work}/$1"
}

# expect_problem <case> <fixture> <want text> — the fixture breaks a rule.
expect_problem() {
  local out
  out="$(problems "${work}/$2")"
  case "$out" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a problem containing '$3', got: ${out:-none}" ;;
  esac
}

# expect_clean <case> <fixture>
expect_clean() {
  local out
  out="$(problems "${work}/$2")"
  if [ -n "$out" ]; then
    fail_case "$1" "unexpected problems: ${out}"
  else
    pass_case "$1"
  fi
}

input_block='    inputs:
      container-prefix:
        type: string
        required: false
        default: prod
        description: Container image name prefix (prod or dev).'

# shellcheck disable=SC2016 # fixture workflows hold literal expressions
{
  fixture good.yml "on:
  workflow_call:
${input_block}
jobs:
  a:
    runs-on: ubuntu-latest
    container: ghcr.io/vergil-project/\${{ inputs.container-prefix || 'prod' }}-base:latest
    steps: [{run: 'true'}]
  m:
    runs-on: ubuntu-latest
    outputs:
      build: \${{ steps.images.outputs.build }}
    steps:
      - id: images
        uses: ./actions/package/image-prefix
        with:
          container-prefix: \${{ inputs.container-prefix }}
  b:
    needs: m
    runs-on: ubuntu-latest
    container: \${{ matrix.image }}
    strategy:
      matrix:
        include: \${{ fromJSON(needs.m.outputs.build) }}
    steps: [{run: 'true'}]
  c:
    uses: ./.github/workflows/good.yml
    with:
      container-prefix: \${{ inputs.container-prefix }}"

  fixture literal.yml "on:
  workflow_call:
${input_block}
jobs:
  a:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/vergil-project/prod-base:latest
    steps: [{run: 'true'}]"

  fixture no-input.yml "on:
  workflow_call: {}
jobs:
  a:
    runs-on: ubuntu-latest
    container: ghcr.io/vergil-project/\${{ inputs.container-prefix || 'prod' }}-base:latest
    steps: [{run: 'true'}]"

  fixture raw-matrix.yml "on:
  workflow_call:
${input_block}
jobs:
  m:
    runs-on: ubuntu-latest
    outputs:
      build: \${{ steps.resolve.outputs.build }}
    steps:
      - id: resolve
        run: vrg-package matrix --github-output
  b:
    needs: m
    runs-on: ubuntu-latest
    container: \${{ matrix.image }}
    strategy:
      matrix:
        include: \${{ fromJSON(needs.m.outputs.build) }}
    steps: [{run: 'true'}]"

  fixture unpassed.yml "on:
  workflow_call:
${input_block}
jobs:
  m:
    runs-on: ubuntu-latest
    outputs:
      build: \${{ steps.images.outputs.build }}
    steps:
      - id: images
        uses: ./actions/package/image-prefix
        with:
          container-prefix: dev
  b:
    needs: m
    runs-on: ubuntu-latest
    container: \${{ matrix.image }}
    strategy:
      matrix:
        include: \${{ fromJSON(needs.m.outputs.build) }}
    steps: [{run: 'true'}]
  c:
    uses: vergil-project/vergil-actions/.github/workflows/good.yml@v2.1"

  fixture other-image.yml "on:
  workflow_call:
${input_block}
jobs:
  a:
    runs-on: ubuntu-latest
    container: ghcr.io/vergil-project/\${{ inputs.flavour }}-base:latest
    steps: [{run: 'true'}]"

  fixture not-reusable.yml "on:
  push: {}
jobs:
  a:
    runs-on: ubuntu-latest
    container: ghcr.io/vergil-project/prod-base:latest
    steps: [{run: 'true'}]"
}

case_real_workflows
expect_clean "fixture-every-form-honours-the-input" good.yml
expect_problem "fixture-catches-a-literal-prod-image" literal.yml \
  "names a prod image literally: ghcr.io/vergil-project/prod-base:latest"
expect_problem "fixture-catches-a-literal-prod-container" literal.yml \
  "a: container ghcr.io/vergil-project/prod-base:latest does not take its prefix"
expect_problem "fixture-catches-a-missing-input" no-input.yml \
  "does not declare container-prefix"
expect_problem "fixture-catches-a-matrix-without-the-prefix" raw-matrix.yml \
  "b: m step resolve does not apply the prefix"
expect_problem "fixture-catches-a-fixed-prefix" unpassed.yml \
  "b: m step images gets container-prefix dev"
expect_problem "fixture-catches-a-call-that-drops-the-prefix" unpassed.yml \
  "c: calls good.yml without passing container-prefix on"
expect_problem "fixture-catches-another-image-expression" other-image.yml \
  "does not take its prefix from container-prefix"
expect_clean "fixture-skips-a-non-reusable-workflow" not-reusable.yml

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
