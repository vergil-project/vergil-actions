#!/usr/bin/env bash
#
# Test ci-package.yml's `container-prefix` input (issue #1132): the matrix
# job's "Apply container prefix" step rewrites the
# `ghcr.io/vergil-project/prod-pkg-` start of every cell's image in the
# `vrg-package matrix` outputs to `<prefix>-pkg-`, passes the outputs on byte
# for byte with the default `prod`, and fails on any other prefix or on a
# missing or malformed output.
#
# Framework-free and developer-runnable: `bash package-image-prefix.test.sh`.
# CI runs it from .github/workflows/smoke-cd-release.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners) and `jq`, and
# touches no network.
#
# Two kinds of case:
#   * structure — the input is declared (string, optional, default prod), the
#     matrix job's `build` and `test` outputs come from the `images` step,
#     which runs after the resolve step and the [package] check and takes the
#     prefix and the resolved outputs through env (never interpolated into
#     its script), and the build and install-test jobs run in each cell's
#     `image`.
#   * behaviour — the step's own script, read from the workflow, runs against
#     fixture outputs with a scratch $GITHUB_OUTPUT.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
wf="${repo_root}/.github/workflows/ci-package.yml"

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

step_q() {
  yq -r ".jobs.matrix.steps[] | select(.id == \"images\") | $1" "$wf"
}

case_input_declared() {
  local name="container-prefix-input-declared" q='.on.workflow_call.inputs."container-prefix"'
  expect "$name" "type" "$(yq -r "${q}.type" "$wf")" "string" || return 0
  expect "$name" "required" "$(yq -r "${q}.required" "$wf")" "false" || return 0
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

case_wiring() {
  local name="images-step-wiring" names idx at_resolve="" at_require="" at_images="" run
  # shellcheck disable=SC2016 # literal GitHub Actions expressions the workflow must contain
  {
    expect "$name" "build output" "$(yq -r '.jobs.matrix.outputs.build' "$wf")" \
      '${{ steps.images.outputs.build }}' || return 0
    expect "$name" "test output" "$(yq -r '.jobs.matrix.outputs.test' "$wf")" \
      '${{ steps.images.outputs.test }}' || return 0
    expect "$name" "PREFIX env" "$(step_q .env.PREFIX)" '${{ inputs.container-prefix }}' || return 0
    expect "$name" "BUILD env" "$(step_q .env.BUILD)" '${{ steps.resolve.outputs.build }}' || return 0
    expect "$name" "TEST env" "$(step_q .env.TEST)" '${{ steps.resolve.outputs.test }}' || return 0
    expect "$name" "build container" "$(yq -r '.jobs.build.container' "$wf")" \
      '${{ matrix.image }}' || return 0
    expect "$name" "install-test container" "$(yq -r '.jobs."install-test".container' "$wf")" \
      '${{ matrix.image }}' || return 0
    expect "$name" "build matrix" "$(yq -r '.jobs.build.strategy.matrix.include' "$wf")" \
      '${{ fromJSON(needs.matrix.outputs.build) }}' || return 0
    expect "$name" "install-test matrix" \
      "$(yq -r '.jobs."install-test".strategy.matrix.include' "$wf")" \
      '${{ fromJSON(needs.matrix.outputs.test) }}' || return 0
  }
  run="$(step_q .run)"
  # shellcheck disable=SC2016 # a literal expression opener the script must not contain
  case "$run" in
    *'${{'*)
      fail_case "$name" "the images step interpolates an expression into its script"
      return 0
      ;;
  esac
  mapfile -t names < <(yq -r '.jobs.matrix.steps[] | (.id // .name)' "$wf")
  for idx in "${!names[@]}"; do
    case "${names[$idx]}" in
      resolve) at_resolve="$idx" ;;
      "Require a [package] section") at_require="$idx" ;;
      images) at_images="$idx" ;;
    esac
  done
  if [ -z "$at_resolve" ] || [ -z "$at_require" ] || [ -z "$at_images" ]; then
    fail_case "$name" "the matrix job lacks the resolve, [package] check or images step: ${names[*]}"
    return 0
  fi
  if ! [ "$at_resolve" -lt "$at_require" ] || ! [ "$at_require" -lt "$at_images" ]; then
    fail_case "$name" "the images step must follow the resolve step and the [package] check: ${names[*]}"
    return 0
  fi
  pass_case "$name"
}

# Fixtures and the step's script.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script="${work}/images.sh"
step_q .run >"$script"
if [ ! -s "$script" ]; then
  fail_case "images-step-script" "ci-package.yml's matrix job has no images step script"
fi

# Spaces after ':' and ',' are not what `jq -c` writes, so a passed-through
# value can be told from a re-serialized one.
build_in='[{"id": "ubuntu-24.04-amd64", "runner": "ubuntu-24.04", "image": "ghcr.io/vergil-project/prod-pkg-ubuntu:24.04", "runtime": "3.14.8"}, {"id": "rhel-9-arm64", "runner": "ubuntu-24.04-arm", "image": "ghcr.io/vergil-project/prod-pkg-rhel:9"}]'
test_in='[{"id": "test-ubuntu-24.04-amd64", "runner": "ubuntu-24.04", "image": "ghcr.io/vergil-project/prod-pkg-ubuntu:24.04", "format": "deb"}]'

# run_step <prefix> <build> <test> — runs the step's script with that env and
# a fresh $GITHUB_OUTPUT; sets rc, log and gho (the output file).
run_step() {
  gho="${work}/github-output"
  : >"$gho"
  rc=0
  log="$(PREFIX="$1" BUILD="$2" TEST="$3" GITHUB_OUTPUT="$gho" bash -e "$script" 2>&1)" || rc=$?
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

case_input_declared
case_wiring
if [ -s "$script" ]; then
  case_prod_passes_through "prod-passes-outputs-through-byte-for-byte" prod
  case_prod_passes_through "empty-prefix-means-prod" ""
  case_dev_rewrites
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
