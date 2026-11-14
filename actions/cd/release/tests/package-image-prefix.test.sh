#!/usr/bin/env bash
#
# Test the `container-prefix` input of the package jobs in ci-package.yml
# (issue #1132) and cd-release.yml (issue #1134). Each workflow's matrix job
# runs the shared actions/package/image-prefix action as its `images` step,
# which rewrites the `ghcr.io/vergil-project/prod-pkg-` start of every cell's
# image in the `vrg-package matrix` outputs to `<prefix>-pkg-`, passes the
# outputs on byte for byte with the default `prod`, and fails on any other
# prefix or on a missing or malformed output.
#
# Framework-free and developer-runnable: `bash package-image-prefix.test.sh`.
# CI runs it from .github/workflows/smoke-cd-release.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners) and `jq`, and
# touches no network.
#
# Three kinds of case:
#   * structure, per workflow — the input is declared (string, optional,
#     default prod), the matrix job's package outputs come from the `images`
#     step, which runs actions/package/image-prefix after the resolve step
#     (and, in ci-package.yml, after the [package] check) with the workflow's
#     prefix and the resolved outputs, and the package jobs run in each
#     cell's `image`.
#   * structure, the action — its inputs reach apply.sh through env (never
#     interpolated into its script) and its outputs come from that step.
#   * behaviour — the action's apply.sh runs against fixture outputs with a
#     scratch $GITHUB_OUTPUT.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"
action_dir="${repo_root}/actions/package/image-prefix"
action_yml="${action_dir}/action.yml"
script="${action_dir}/apply.sh"

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'package-image-prefix.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done

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

# expect <case> <what> <got> <want> — record a mismatch; returns 1 on one.
expect() {
  if [ "$3" != "$4" ]; then
    fail_case "$1" "$2: expected '$4', got '$3'"
    return 1
  fi
}

# input_case <workflow file> — the workflow declares the input.
input_case() {
  local wf="${workflows}/$1" name="$1-container-prefix-input-declared"
  local q='.on.workflow_call.inputs."container-prefix"'
  expect "$name" "type" "$(yq -r "${q}.type" "$wf")" "string" || return 0
  expect "$name" "required" "$(yq -r "${q}.required // false" "$wf")" "false" || return 0
  expect "$name" "default" "$(yq -r "${q}.default" "$wf")" "prod" || return 0
  case "$(yq -r "${q}.description" "$wf")" in
    *"prod or dev"*) ;;
    *)
      fail_case "$name" "the description does not name prod or dev"
      return 0
      ;;
  esac
  pass_case "$name"
}

# wiring_case <workflow file> <matrix job> <after step> <outputs> <job:output>...
# — <matrix job>'s <outputs> (comma-separated) come from its `images` step,
# which runs actions/package/image-prefix after the step whose id or name is
# <after step>, with the workflow's prefix and the resolve step's outputs;
# each <job> runs in its cell's image, from the matrix job's <output>.
wiring_case() {
  local file="$1" mjob="$2" after="$3" outs="$4"
  shift 4
  local wf="${workflows}/${file}" name="${file}-images-step-wiring"
  local out out_list pair job key names idx at_resolve="" at_after="" at_images=""
  local step=".jobs.\"${mjob}\".steps[] | select(.id == \"images\")"
  expect "$name" "images step uses" "$(yq -r "${step} | .uses" "$wf")" \
    "./actions/package/image-prefix" || return 0
  # shellcheck disable=SC2016 # literal GitHub Actions expressions the workflow must contain
  {
    expect "$name" "container-prefix input" \
      "$(yq -r "${step} | .with.\"container-prefix\"" "$wf")" \
      '${{ inputs.container-prefix }}' || return 0
    expect "$name" "build input" "$(yq -r "${step} | .with.build" "$wf")" \
      '${{ steps.resolve.outputs.build }}' || return 0
    expect "$name" "test input" "$(yq -r "${step} | .with.test" "$wf")" \
      '${{ steps.resolve.outputs.test }}' || return 0
  }
  IFS=, read -r -a out_list <<<"$outs"
  for out in "${out_list[@]}"; do
    expect "$name" "${out} output" "$(yq -r ".jobs.\"${mjob}\".outputs.${out}" "$wf")" \
      "\${{ steps.images.outputs.${out} }}" || return 0
  done
  for pair in "$@"; do
    job="${pair%%:*}"
    key="${pair#*:}"
    # shellcheck disable=SC2016 # a literal GitHub Actions expression the workflow must contain
    expect "$name" "${job} container" "$(yq -r ".jobs.\"${job}\".container" "$wf")" \
      '${{ matrix.image }}' || return 0
    expect "$name" "${job} matrix" "$(yq -r ".jobs.\"${job}\".strategy.matrix.include" "$wf")" \
      "\${{ fromJSON(needs.${mjob}.outputs.${key}) }}" || return 0
  done
  mapfile -t names < <(yq -r ".jobs.\"${mjob}\".steps[] | (.id // .name)" "$wf")
  for idx in "${!names[@]}"; do
    case "${names[$idx]}" in
      resolve) at_resolve="$idx" ;;
      images) at_images="$idx" ;;
    esac
    if [ "${names[$idx]}" = "$after" ]; then
      at_after="$idx"
    fi
  done
  if [ -z "$at_resolve" ] || [ -z "$at_after" ] || [ -z "$at_images" ]; then
    fail_case "$name" "the ${mjob} job lacks the resolve, '${after}' or images step: ${names[*]}"
    return 0
  fi
  if [ "$at_resolve" -gt "$at_after" ] || ! [ "$at_after" -lt "$at_images" ]; then
    fail_case "$name" "the images step must follow the resolve step and '${after}': ${names[*]}"
    return 0
  fi
  pass_case "$name"
}

case_action_wiring() {
  local name="image-prefix-action-wiring" step='.runs.steps[] | select(.id == "apply")'
  expect "$name" "runs using" "$(yq -r '.runs.using' "$action_yml")" "composite" || return 0
  # shellcheck disable=SC2016 # literal GitHub Actions expressions the action must contain
  {
    expect "$name" "PREFIX env" "$(yq -r "${step} | .env.PREFIX" "$action_yml")" \
      '${{ inputs.container-prefix }}' || return 0
    expect "$name" "BUILD env" "$(yq -r "${step} | .env.BUILD" "$action_yml")" \
      '${{ inputs.build }}' || return 0
    expect "$name" "TEST env" "$(yq -r "${step} | .env.TEST" "$action_yml")" \
      '${{ inputs.test }}' || return 0
    expect "$name" "run" "$(yq -r "${step} | .run" "$action_yml")" \
      'bash "${GITHUB_ACTION_PATH}/apply.sh"' || return 0
    expect "$name" "build output" "$(yq -r '.outputs.build.value' "$action_yml")" \
      '${{ steps.apply.outputs.build }}' || return 0
    expect "$name" "test output" "$(yq -r '.outputs.test.value' "$action_yml")" \
      '${{ steps.apply.outputs.test }}' || return 0
  }
  expect "$name" "build required" "$(yq -r '.inputs.build.required' "$action_yml")" "true" || return 0
  expect "$name" "test required" "$(yq -r '.inputs.test.required' "$action_yml")" "true" || return 0
  pass_case "$name"
}

# Fixtures.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Spaces after ':' and ',' are not what `jq -c` writes, so a passed-through
# value can be told from a re-serialized one.
build_in='[{"id": "ubuntu-24.04-amd64", "runner": "ubuntu-24.04", "image": "ghcr.io/vergil-project/prod-pkg-ubuntu:24.04", "runtime": "3.14.8"}, {"id": "rhel-9-arm64", "runner": "ubuntu-24.04-arm", "image": "ghcr.io/vergil-project/prod-pkg-rhel:9"}]'
test_in='[{"id": "test-ubuntu-24.04-amd64", "runner": "ubuntu-24.04", "image": "ghcr.io/vergil-project/prod-pkg-ubuntu:24.04", "format": "deb"}]'

# run_step <prefix> <build> <test> — runs apply.sh with that env and a fresh
# $GITHUB_OUTPUT; sets rc, log and gho (the output file).
run_step() {
  gho="${work}/github-output"
  : >"$gho"
  rc=0
  log="$(PREFIX="$1" BUILD="$2" TEST="$3" GITHUB_OUTPUT="$gho" bash "$script" 2>&1)" || rc=$?
}

# output <key> — the value the step wrote for <key>.
output() {
  sed -n "s/^${1}=//p" "$gho"
}

case_prod_passes_through() {
  local name="$1" prefix="$2"
  run_step "$prefix" "$build_in" "$test_in"
  expect "$name" "exit status" "$rc" "0" || {
    printf '%s\n' "$log" >&2
    return 0
  }
  expect "$name" "build output" "$(output build)" "$build_in" || return 0
  expect "$name" "test output" "$(output test)" "$test_in" || return 0
  expect "$name" "output lines" "$(wc -l <"$gho" | tr -d ' ')" "2" || return 0
  case "$log" in
    *"container prefix: prod"*"build / ubuntu-24.04-amd64: ghcr.io/vergil-project/prod-pkg-ubuntu:24.04"*"build / rhel-9-arm64: ghcr.io/vergil-project/prod-pkg-rhel:9"*"test / test-ubuntu-24.04-amd64: ghcr.io/vergil-project/prod-pkg-ubuntu:24.04"*) ;;
    *)
      fail_case "$name" "the log does not show each cell's image: ${log}"
      return 0
      ;;
  esac
  case "$log" in
    *"::warning::"*)
      fail_case "$name" "unexpected warning: ${log}"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_dev_rewrites() {
  local name="dev-rewrites-only-the-image-prefix" build_with_other want_build want_test
  # A cell whose image is not a vergil package image keeps it, with a warning.
  build_with_other="$(printf '%s' "$build_in" |
    jq -c '. + [{"id": "other", "image": "docker.io/library/debian:12"}]')"
  run_step dev "$build_with_other" "$test_in"
  expect "$name" "exit status" "$rc" "0" || {
    printf '%s\n' "$log" >&2
    return 0
  }
  want_build='[{"id":"ubuntu-24.04-amd64","runner":"ubuntu-24.04","image":"ghcr.io/vergil-project/dev-pkg-ubuntu:24.04","runtime":"3.14.8"},{"id":"rhel-9-arm64","runner":"ubuntu-24.04-arm","image":"ghcr.io/vergil-project/dev-pkg-rhel:9"},{"id":"other","image":"docker.io/library/debian:12"}]'
  want_test='[{"id":"test-ubuntu-24.04-amd64","runner":"ubuntu-24.04","image":"ghcr.io/vergil-project/dev-pkg-ubuntu:24.04","format":"deb"}]'
  expect "$name" "build output" "$(output build)" "$want_build" || return 0
  expect "$name" "test output" "$(output test)" "$want_test" || return 0
  case "$log" in
    *"container prefix: dev"*"build / ubuntu-24.04-amd64: ghcr.io/vergil-project/dev-pkg-ubuntu:24.04"*"build / rhel-9-arm64: ghcr.io/vergil-project/dev-pkg-rhel:9"*"build / other: docker.io/library/debian:12"*"test / test-ubuntu-24.04-amd64: ghcr.io/vergil-project/dev-pkg-ubuntu:24.04"*) ;;
    *)
      fail_case "$name" "the log does not show each cell's image: ${log}"
      return 0
      ;;
  esac
  case "$log" in
    *"::warning::build / other: image 'docker.io/library/debian:12' is not under 'ghcr.io/vergil-project/prod-pkg-'"*) ;;
    *)
      fail_case "$name" "no warning for the non-package image: ${log}"
      return 0
      ;;
  esac
  pass_case "$name"
}

# A repo without [package] (cd-release.yml runs the step for every caller)
# has `[]` outputs: passed on as `[]` with either prefix.
case_empty_matrix() {
  local name="$1" prefix="$2"
  run_step "$prefix" "[]" "[]"
  expect "$name" "exit status" "$rc" "0" || {
    printf '%s\n' "$log" >&2
    return 0
  }
  expect "$name" "build output" "$(output build)" "[]" || return 0
  expect "$name" "test output" "$(output test)" "[]" || return 0
  expect "$name" "output lines" "$(wc -l <"$gho" | tr -d ' ')" "2" || return 0
  pass_case "$name"
}

# refuse_case <name> <prefix> <build> <test> <want log text>
refuse_case() {
  local name="$1"
  run_step "$2" "$3" "$4"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the step passed: ${log}"
    return 0
  fi
  if [ -s "$gho" ]; then
    fail_case "$name" "the step wrote outputs before failing: $(cat "$gho")"
    return 0
  fi
  case "$log" in
    *"::error::"*"$5"*) ;;
    *)
      fail_case "$name" "expected an error containing '$5', got: ${log}"
      return 0
      ;;
  esac
  pass_case "$name"
}

input_case ci-package.yml
input_case cd-release.yml
wiring_case ci-package.yml matrix "Require a [package] section" build,test \
  build:build install-test:test
wiring_case cd-release.yml package-matrix resolve build \
  package-build:build
case_action_wiring
if [ ! -s "$script" ]; then
  fail_case "image-prefix-script" "actions/package/image-prefix/apply.sh is missing or empty"
else
  case_prod_passes_through "prod-passes-outputs-through-byte-for-byte" prod
  case_prod_passes_through "empty-prefix-means-prod" ""
  case_dev_rewrites
  case_empty_matrix "prod-passes-an-empty-matrix-through" prod
  case_empty_matrix "dev-passes-an-empty-matrix-through" dev
  refuse_case "rejects-an-unknown-prefix" staging "$build_in" "$test_in" \
    "invalid container-prefix input 'staging' (expected prod or dev)"
  refuse_case "rejects-a-prefix-with-a-path" "dev-pkg-x/../prod" "$build_in" "$test_in" \
    "invalid container-prefix input"
  refuse_case "rejects-a-missing-build-output" dev "" "$test_in" \
    "vrg-package matrix wrote no 'build' output"
  refuse_case "rejects-a-missing-test-output" prod "$build_in" "" \
    "vrg-package matrix wrote no 'test' output"
  refuse_case "rejects-a-non-json-output" dev "not json" "$test_in" \
    "'build' output is not a one-line JSON array"
  refuse_case "rejects-a-cell-without-an-image" dev '[{"id": "a"}]' "$test_in" \
    "'build' output is not a one-line JSON array"
  refuse_case "rejects-a-multi-line-output" prod "$build_in" "$(printf '[\n]')" \
    "'test' output is not a one-line JSON array"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
