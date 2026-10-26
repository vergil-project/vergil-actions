#!/usr/bin/env bash
#
# Test that every single-container workflow job runs on the resolver's image
# for the primary version, never on a suffix taken from caller inputs (issues
# #1020 and #1028, epic vergil-project/.github#407).
#
# Framework-free and developer-runnable: `bash image.test.sh`. CI runs it from
# .github/workflows/smoke-setup-vergil.yml. It needs `yq` (mikefarah v4,
# preinstalled on GitHub's ubuntu runners), `jq`, and the real `vrg-ci-resolve`
# (vergil-tooling v2.1) on PATH. Every resolver call reads the fixture window
# through VRG_VERSION_WINDOW, so no case touches the network.
#
# The single-container jobs are ci-quality's `common` and `custom`,
# ci-version-bump's `version-bump` and cd-release's `release`. Three kinds of
# case:
#   * structure — each job's workflow has a `setup` job that runs the shared
#     setup action (id derive) and shared/setup/primary-suffix (id suffix) on
#     its primary-version and container-suffixes, with the caller's
#     container-suffix as the cross-check, and exports
#     primary-container-suffix and primary-container-tag; the job needs
#     `setup` and its `container:` is built from those two outputs. And no job
#     in any workflow builds its `container:` from `inputs.container-suffix`
#     or `inputs.language`.
#   * resolve.sh — loud failure on empty or malformed inputs.
#   * resolution — for a fixture repo, each job's `container:` expression,
#     filled in with derive.sh's and resolve.sh's outputs, names the image
#     whose suffix and tag are vrg-ci-resolve's for the primary version
#     (C++ clang-20 -> prod-cpp-clang:20, Python -> prod-python:<primary>, a
#     language-less repo -> prod-base:latest); and a caller container-suffix
#     that disagrees with the resolver fails resolve.sh loudly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"
derive_sh="${repo_root}/actions/shared/setup/vergil/derive.sh"
suffix_sh="${repo_root}/actions/shared/setup/primary-suffix/resolve.sh"
window="${repo_root}/actions/shared/setup/vergil/tests/fixtures/window.json"

# <workflow file>:<job> for every single-container job.
jobs=(
  "ci-quality.yml:common"
  "ci-quality.yml:custom"
  "ci-version-bump.yml:version-bump"
  "cd-release.yml:release"
)

for tool in yq jq vrg-ci-resolve; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'image.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done
for f in "$derive_sh" "$suffix_sh" "$window"; do
  if [ ! -f "$f" ]; then
    printf 'image.test.sh: missing %s\n' "$f" >&2
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

# q <workflow file> <yq expression>
q() {
  yq -r "$2" "${workflows}/$1"
}

want_container="ghcr.io/vergil-project/\${{ inputs.container-prefix || 'prod' }}-\${{ needs.setup.outputs.primary-container-suffix }}:\${{ needs.setup.outputs.primary-container-tag }}"

# case_structure <workflow file> <job>
case_structure() {
  local wf="$1" job="$2" name step
  name="${wf%.yml}-${job}-runs-on-the-resolved-image"
  if [ ! -f "${workflows}/${wf}" ]; then
    fail_case "$name" "no workflow ${wf}"
    return 0
  fi
  expect "$name" "setup primary-container-tag output" \
    "$(q "$wf" '.jobs.setup.outputs."primary-container-tag"')" \
    '${{ steps.derive.outputs.primary-container-tag }}' || return 0
  expect "$name" "setup primary-container-suffix output" \
    "$(q "$wf" '.jobs.setup.outputs."primary-container-suffix"')" \
    '${{ steps.suffix.outputs.primary-container-suffix }}' || return 0
  expect "$name" "derive step" \
    "$(q "$wf" '[.jobs.setup.steps[] | select(.id == "derive") | .uses] | join(",")')" \
    "./actions/shared/setup/vergil" || return 0
  step="$(q "$wf" '.jobs.setup.steps[] | select(.id == "suffix")')"
  if [ -z "$step" ]; then
    fail_case "$name" "setup has no step with id suffix"
    return 0
  fi
  expect "$name" "suffix step uses" "$(printf '%s\n' "$step" | yq -r '.uses')" \
    "./actions/shared/setup/primary-suffix" || return 0
  expect "$name" "primary-version" \
    "$(printf '%s\n' "$step" | yq -r '.with."primary-version"')" \
    '${{ steps.derive.outputs.primary-version }}' || return 0
  expect "$name" "container-suffixes" \
    "$(printf '%s\n' "$step" | yq -r '.with."container-suffixes"')" \
    '${{ steps.derive.outputs.container-suffixes }}' || return 0
  expect "$name" "container-suffix cross-check" \
    "$(printf '%s\n' "$step" | yq -r '.with."container-suffix"')" \
    '${{ inputs.container-suffix }}' || return 0
  if ! q "$wf" ".jobs.\"${job}\".needs | [.] | flatten | .[]" | grep -qx setup; then
    fail_case "$name" "${job} does not need setup"
    return 0
  fi
  expect "$name" "${job} container" "$(q "$wf" ".jobs.\"${job}\".container")" \
    "$want_container" || return 0
  pass_case "$name"
}

# No job in any workflow builds its image from the caller's container-suffix
# or language (issue #1028).
case_no_caller_suffix_images() {
  local name="no-job-image-from-a-caller-suffix" wf hits=""
  for wf in "$workflows"/*.yml; do
    if yq -r '.jobs[]?.container // "" | tostring' "$wf" |
      grep -q 'inputs\.\(container-suffix\|language\)'; then
      hits="${hits} $(basename "$wf")"
    fi
  done
  expect "$name" "workflows with an input-suffixed container" "${hits# }" "" || return 0
  pass_case "$name"
}

# Result of the last run_suffix.
rc=0
stderr=""
suffix=""

# run_suffix <PRIMARY> <CONTAINER_SUFFIXES> <SUFFIX> — run resolve.sh; sets
# suffix (its output), rc and stderr.
run_suffix() {
  local o e
  o="$(mktemp)"
  e="$(mktemp)"
  rc=0
  PRIMARY="$1" CONTAINER_SUFFIXES="$2" SUFFIX="$3" GITHUB_OUTPUT="$o" \
    bash "$suffix_sh" >/dev/null 2>"$e" || rc=$?
  stderr="$(cat "$e")"
  suffix="$(sed -n 's/^primary-container-suffix=//p' "$o")"
  rm -f "$o" "$e"
}

# expect_failure <case> <want error substring> — after run_suffix.
expect_failure() {
  if [ "$rc" -eq 0 ]; then
    fail_case "$1" "expected resolve.sh to fail, it output '${suffix}'"
    return 1
  fi
  case "$stderr" in
    *"::error::"*"$2"*) ;;
    *)
      fail_case "$1" "expected ::error:: containing '$2', got '$stderr'"
      return 1
      ;;
  esac
  expect "$1" "suffix output on failure" "$suffix" "" || return 1
}

# input_case <name> <PRIMARY> <CONTAINER_SUFFIXES> <want error>
input_case() {
  run_suffix "$2" "$3" ""
  expect_failure "$1" "$4" || return 0
  pass_case "$1"
}

# Result of the last derive_fixture.
dir=""
so=""

# derive_fixture <name> <language|""> <[ci] lines> — write a fixture repo to
# $dir and run derive.sh on it into $so. Returns 1 (case failed) on error.
derive_fixture() {
  local name="$1" lang="$2" ci="$3"
  dir="$(mktemp -d)"
  so="$(mktemp)"
  {
    printf '[project]\nrepository-type = "library"\n'
    printf 'versioning-scheme = "semver"\nbranching-model = "library-release"\n'
    printf 'release-model = "tagged-release"\n'
    if [ -n "$lang" ]; then printf 'primary-language = "%s"\n' "$lang"; fi
    printf '\n[dependencies]\nvergil = "v2.1"\n\n[ci]\nintegration-tests = false\n%s\n' "$ci"
  } >"${dir}/vergil.toml"
  if ! VERGIL_CONFIG_DIR="$dir" VRG_VERSION_WINDOW="$window" GITHUB_OUTPUT="$so" \
    bash "$derive_sh" >/dev/null 2>&1; then
    fail_case "$name" "derive.sh failed for the fixture"
    rm -rf "$dir" "$so"
    return 1
  fi
}

# out <key> — a value derive.sh wrote to $so.
out() {
  sed -n "s/^$1=//p" "$so"
}

# render_image <workflow file> <job> <suffix> — fill in the job's container
# expression with the default prefix, <suffix> and derive's tag.
render_image() {
  local image
  image="$(q "$1" ".jobs.\"$2\".container")"
  image="${image//"\${{ inputs.container-prefix || 'prod' }}"/prod}"
  image="${image//"\${{ needs.setup.outputs.primary-container-suffix }}"/$3}"
  image="${image//"\${{ needs.setup.outputs.primary-container-tag }}"/$(out primary-container-tag)}"
  printf '%s' "$image"
}

# resolve_case <name> <language|""> <[ci] lines> <caller suffix|""> <want image>
# — for every single-container job.
resolve_case() {
  local name="$1" lang="$2" ci="$3" caller="$4" want="$5" direct entry wf job image
  derive_fixture "$name" "$lang" "$ci" || return 0
  run_suffix "$(out primary-version)" "$(out container-suffixes)" "$caller"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "resolve.sh failed (exit ${rc}): ${stderr}"
    rm -rf "$dir" "$so"
    return 0
  fi
  direct="$(VRG_VERSION_WINDOW="$window" vrg-ci-resolve --format json --repo-root "$dir" |
    jq -r '"prod-" + ."container-suffixes"[."primary-version"] + ":" + ."primary-container-tag"')"
  for entry in "${jobs[@]}"; do
    wf="${entry%%:*}"
    job="${entry#*:}"
    image="$(render_image "$wf" "$job" "$suffix")"
    if ! expect "$name" "${wf} ${job} image" "$image" "$want" ||
      ! expect "$name" "${wf} ${job} image vs vrg-ci-resolve" "${image##*/}" "$direct"; then
      rm -rf "$dir" "$so"
      return 0
    fi
  done
  rm -rf "$dir" "$so"
  pass_case "$name"
}

# mismatch_case <name> <language|""> <[ci] lines> <caller suffix> <want error>
mismatch_case() {
  local name="$1" lang="$2" ci="$3" caller="$4" want="$5"
  derive_fixture "$name" "$lang" "$ci" || return 0
  run_suffix "$(out primary-version)" "$(out container-suffixes)" "$caller"
  rm -rf "$dir" "$so"
  expect_failure "$name" "$want" || return 0
  pass_case "$name"
}

for entry in "${jobs[@]}"; do
  case_structure "${entry%%:*}" "${entry#*:}"
done
case_no_caller_suffix_images

input_case "empty-primary-version-fails" "" '{"3.14":"python"}' "PRIMARY is empty"
input_case "empty-container-suffixes-fails" "3.14" "" "CONTAINER_SUFFIXES is empty"
input_case "non-object-container-suffixes-fails" "3.14" '["python"]' \
  "container-suffixes must be a JSON object"
input_case "primary-missing-from-container-suffixes-fails" "3.15" '{"3.14":"python"}' \
  "no suffix for the primary version '3.15'"

resolve_case "cpp-clang-20-resolves-prod-cpp-clang" cpp 'versions = ["clang-20"]' "" \
  "ghcr.io/vergil-project/prod-cpp-clang:20"
resolve_case "cpp-clang-20-matching-caller-suffix" cpp 'versions = ["clang-20"]' cpp-clang \
  "ghcr.io/vergil-project/prod-cpp-clang:20"
resolve_case "cpp-two-families-resolves-the-primary" cpp 'versions = ["clang-20", "gcc-14"]' "" \
  "ghcr.io/vergil-project/prod-cpp-clang:20"
resolve_case "typescript-node-24-resolves-prod-ts-node" typescript 'versions = ["node-24"]' "" \
  "ghcr.io/vergil-project/prod-ts-node:24"
resolve_case "python-library-resolves-primary" python "" "" \
  "ghcr.io/vergil-project/prod-python:3.15"
resolve_case "python-matching-caller-suffix" python "" python \
  "ghcr.io/vergil-project/prod-python:3.15"
resolve_case "python-primary-override" python 'primary-version = "3.14"' python \
  "ghcr.io/vergil-project/prod-python:3.14"
resolve_case "no-language-resolves-prod-base" "" 'versions = ["latest"]' "" \
  "ghcr.io/vergil-project/prod-base:latest"
resolve_case "no-language-matching-caller-suffix-base" "" 'versions = ["latest"]' base \
  "ghcr.io/vergil-project/prod-base:latest"

mismatch_case "cpp-caller-suffix-cpp-fails" cpp 'versions = ["clang-20"]' cpp \
  "container-suffix 'cpp' does not match"
mismatch_case "cpp-caller-suffix-base-fails" cpp 'versions = ["clang-20"]' base \
  "container-suffix 'base' does not match"
mismatch_case "cpp-caller-suffix-non-primary-family-fails" cpp \
  'versions = ["clang-20", "gcc-14"]' cpp-gcc \
  "container-suffix 'cpp-gcc' does not match"
mismatch_case "python-caller-suffix-base-fails" python "" base \
  "container-suffix 'base' does not match"
mismatch_case "no-language-caller-suffix-python-fails" "" 'versions = ["latest"]' python \
  "container-suffix 'python' does not match"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
