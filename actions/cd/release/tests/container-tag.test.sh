#!/usr/bin/env bash
#
# Test that cd-release.yml runs its release job on the resolver's primary
# image, suffix and tag, not on caller inputs (issues #1017 and #1020, epic
# vergil-project/.github#407).
#
# Framework-free and developer-runnable: `bash container-tag.test.sh`. CI runs
# it from .github/workflows/smoke-cd-release.yml. It needs `yq` (mikefarah v4,
# preinstalled on GitHub's ubuntu runners), `jq`, and the real `vrg-ci-resolve`
# (vergil-tooling v2.1) on PATH. Every resolver call reads the fixture window
# through VRG_VERSION_WINDOW, so no case touches the network.
#
# Two kinds of case:
#   * structure — cd-release.yml's `setup` job runs the shared setup action
#     and exports its primary-container-tag, and runs cd/release/primary-suffix
#     on the setup action's primary-version and container-suffixes (with the
#     caller's container-suffix as the cross-check) and exports its
#     primary-container-suffix; `release` needs `setup`, refuses to run
#     without it, and takes its image suffix and tag (and its validate-inputs
#     tag) from it; the deprecated `container-tag` input defaults to empty and
#     is read only by the step that warns about it; no other workflow job
#     builds its image from a caller's `container-tag`, and no cd-release job
#     builds its image from a caller's `container-suffix` or `language`.
#   * resolution — for a fixture repo, the release job's `container:`
#     expression, filled in with the setup action's derive.sh outputs and
#     primary-suffix's resolve.sh output, names the image whose suffix and tag
#     are `vrg-ci-resolve`'s for the primary version; and a caller
#     container-suffix that disagrees with it fails resolve.sh loudly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
cd_release_yml="${repo_root}/.github/workflows/cd-release.yml"
workflows="${repo_root}/.github/workflows"
derive_sh="${repo_root}/actions/shared/setup/vergil/derive.sh"
suffix_sh="${repo_root}/actions/cd/release/primary-suffix/resolve.sh"
window="${repo_root}/actions/shared/setup/vergil/tests/fixtures/window.json"

for tool in yq jq vrg-ci-resolve; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'container-tag.test.sh needs %s on PATH\n' "$tool" >&2
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

# q <yq expression> — query cd-release.yml.
q() {
  yq -r "$1" "$cd_release_yml"
}

# expect <case> <what> <got> <want> — record a mismatch; returns 1 on one.
expect() {
  if [ "$3" != "$4" ]; then
    fail_case "$1" "$2: expected '$4', got '$3'"
    return 1
  fi
}

case_setup_job() {
  local name="setup-job-derives-the-tag" steps
  expect "$name" "setup output" \
    "$(q '.jobs.setup.outputs."primary-container-tag"')" \
    '${{ steps.derive.outputs.primary-container-tag }}' || return 0
  steps="$(q '[.jobs.setup.steps[] | select(.id == "derive") | .uses] | join(",")')"
  expect "$name" "derive step" "$steps" "./actions/shared/setup/vergil" || return 0
  expect "$name" "setup container" "$(q '.jobs.setup.container')" "null" || return 0
  pass_case "$name"
}

# The suffix step: primary-suffix on the derive step's answer, the caller's
# container-suffix passed only as its cross-check, exported by setup.
case_setup_suffix() {
  local name="setup-job-derives-the-suffix" step
  expect "$name" "setup output" \
    "$(q '.jobs.setup.outputs."primary-container-suffix"')" \
    '${{ steps.suffix.outputs.primary-container-suffix }}' || return 0
  step="$(q '.jobs.setup.steps[] | select(.id == "suffix")')"
  if [ -z "$step" ]; then
    fail_case "$name" "setup has no step with id suffix"
    return 0
  fi
  expect "$name" "suffix step uses" "$(printf '%s\n' "$step" | yq -r '.uses')" \
    "./actions/cd/release/primary-suffix" || return 0
  expect "$name" "primary-version" \
    "$(printf '%s\n' "$step" | yq -r '.with."primary-version"')" \
    '${{ steps.derive.outputs.primary-version }}' || return 0
  expect "$name" "container-suffixes" \
    "$(printf '%s\n' "$step" | yq -r '.with."container-suffixes"')" \
    '${{ steps.derive.outputs.container-suffixes }}' || return 0
  expect "$name" "container-suffix cross-check" \
    "$(printf '%s\n' "$step" | yq -r '.with."container-suffix"')" \
    '${{ inputs.container-suffix }}' || return 0
  pass_case "$name"
}

case_release_uses_setup() {
  local name="release-runs-on-the-derived-tag" image if_expr validate
  if ! q '.jobs.release.needs[]' | grep -qx setup; then
    fail_case "$name" "release does not need setup"
    return 0
  fi
  if_expr="$(q '.jobs.release.if')"
  case "$if_expr" in
    *"needs.setup.result == 'success'"*) ;;
    *)
      fail_case "$name" "release's if does not require needs.setup.result == 'success': $if_expr"
      return 0
      ;;
  esac
  image="$(q '.jobs.release.container')"
  expect "$name" "release container" "$image" \
    "ghcr.io/vergil-project/\${{ inputs.container-prefix || 'prod' }}-\${{ needs.setup.outputs.primary-container-suffix }}:\${{ needs.setup.outputs.primary-container-tag }}" ||
    return 0
  validate="$(q '.jobs.release.steps[] | select(.uses == "./actions/cd/release/validate-inputs") | .with."container-tag"')"
  expect "$name" "validate-inputs container-tag" "$validate" \
    '${{ needs.setup.outputs.primary-container-tag }}' || return 0
  pass_case "$name"
}

# The deprecated input: optional, empty by default, and read only by the
# warning step, whose message names the follow-up that removes it.
case_deprecated_input() {
  local name="container-tag-input-is-ignored" refs warn
  expect "$name" "default" \
    "$(q '.on.workflow_call.inputs."container-tag".default')" "" || return 0
  expect "$name" "required" \
    "$(q '.on.workflow_call.inputs."container-tag".required // false')" "false" || return 0
  refs="$(grep -c 'inputs\.container-tag' "$cd_release_yml" || true)"
  expect "$name" "inputs.container-tag references" "$refs" "2" || return 0
  warn="$(q '.jobs.setup.steps[] | select(.name == "Warn on the deprecated container-tag input")')"
  if [ -z "$warn" ]; then
    fail_case "$name" "setup has no deprecation warning step"
    return 0
  fi
  expect "$name" "warning condition" \
    "$(printf '%s\n' "$warn" | yq -r '.if')" "inputs.container-tag != ''" || return 0
  expect "$name" "warning env" \
    "$(printf '%s\n' "$warn" | yq -r '.env.CALLER_TAG')" '${{ inputs.container-tag }}' || return 0
  case "$(printf '%s\n' "$warn" | yq -r '.run')" in
    *"::warning::"*"vergil-project/vergil-tooling#3484"*) ;;
    *)
      fail_case "$name" "warning step does not emit a ::warning:: naming vergil-tooling#3484"
      return 0
      ;;
  esac
  pass_case "$name"
}

# No job in any workflow builds its image from a caller's container-tag.
case_no_caller_tag_images() {
  local name="no-job-image-from-a-caller-tag" wf hits=""
  for wf in "$workflows"/*.yml; do
    if yq -r '.jobs[]?.container // "" | tostring' "$wf" | grep -q 'inputs\.container-tag'; then
      hits="${hits} $(basename "$wf")"
    fi
  done
  expect "$name" "workflows with an input-tagged container" "${hits# }" "" || return 0
  pass_case "$name"
}

# No cd-release job builds its image from the caller's container-suffix or
# language (issue #1020): `language: cpp` named the unpublished prod-cpp.
case_no_caller_suffix_images() {
  local name="no-release-image-from-a-caller-suffix" hits
  hits="$(q '[.jobs | to_entries[] | select((.value.container // "" | tostring) |
    test("inputs\\.(container-suffix|language)")) | .key] | join(" ")')"
  expect "$name" "jobs with an input-suffixed container" "$hits" "" || return 0
  pass_case "$name"
}

# Result of the last derive_fixture / run_suffix.
dir=""
so=""
rc=0
stderr=""
suffix=""

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

# run_suffix <caller container-suffix> — run primary-suffix's resolve.sh on
# the derive outputs in $so; sets suffix (its output), rc and stderr.
run_suffix() {
  local o e
  o="$(mktemp)"
  e="$(mktemp)"
  rc=0
  PRIMARY="$(out primary-version)" CONTAINER_SUFFIXES="$(out container-suffixes)" \
    SUFFIX="$1" GITHUB_OUTPUT="$o" bash "$suffix_sh" >/dev/null 2>"$e" || rc=$?
  stderr="$(cat "$e")"
  suffix="$(sed -n 's/^primary-container-suffix=//p' "$o")"
  rm -f "$o" "$e"
}

# render_release_image <suffix> — fill in the release job's container
# expression with the default prefix, <suffix> and derive's tag.
render_release_image() {
  local image
  image="$(q '.jobs.release.container')"
  image="${image//"\${{ inputs.container-prefix || 'prod' }}"/prod}"
  image="${image//"\${{ needs.setup.outputs.primary-container-suffix }}"/$1}"
  image="${image//"\${{ needs.setup.outputs.primary-container-tag }}"/$(out primary-container-tag)}"
  printf '%s' "$image"
}

# resolve_case <name> <language|""> <[ci] lines> <caller suffix|""> <want image>
resolve_case() {
  local name="$1" lang="$2" ci="$3" caller="$4" want="$5" image direct
  derive_fixture "$name" "$lang" "$ci" || return 0
  run_suffix "$caller"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "primary-suffix failed (exit ${rc}): ${stderr}"
    rm -rf "$dir" "$so"
    return 0
  fi
  image="$(render_release_image "$suffix")"
  direct="$(VRG_VERSION_WINDOW="$window" vrg-ci-resolve --format json --repo-root "$dir" |
    jq -r '"prod-" + ."container-suffixes"[."primary-version"] + ":" + ."primary-container-tag"')"
  rm -rf "$dir" "$so"
  expect "$name" "image" "$image" "$want" || return 0
  expect "$name" "image vs vrg-ci-resolve" "${image##*/}" "$direct" || return 0
  pass_case "$name"
}

# mismatch_case <name> <language|""> <[ci] lines> <caller suffix> <want error>
# — a caller container-suffix that disagrees with the resolver fails loudly.
mismatch_case() {
  local name="$1" lang="$2" ci="$3" caller="$4" want="$5"
  derive_fixture "$name" "$lang" "$ci" || return 0
  run_suffix "$caller"
  rm -rf "$dir" "$so"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected primary-suffix to fail, it output '${suffix}'"
    return 0
  fi
  case "$stderr" in
    *"::error::"*"$want"*) ;;
    *)
      fail_case "$name" "expected ::error:: containing '$want', got '$stderr'"
      return 0
      ;;
  esac
  expect "$name" "suffix output on failure" "$suffix" "" || return 0
  pass_case "$name"
}

case_setup_job
case_setup_suffix
case_release_uses_setup
case_deprecated_input
case_no_caller_tag_images
case_no_caller_suffix_images
resolve_case "python-library-resolves-primary" python "" "" \
  "ghcr.io/vergil-project/prod-python:3.15"
resolve_case "python-primary-override" python 'primary-version = "3.14"' "" \
  "ghcr.io/vergil-project/prod-python:3.14"
resolve_case "python-matching-caller-suffix" python "" python \
  "ghcr.io/vergil-project/prod-python:3.15"
resolve_case "no-language-resolves-latest" "" 'versions = ["latest"]' "" \
  "ghcr.io/vergil-project/prod-base:latest"
resolve_case "cpp-clang-20-resolves-prod-cpp-clang" cpp 'versions = ["clang-20"]' "" \
  "ghcr.io/vergil-project/prod-cpp-clang:20"
resolve_case "typescript-node-24-resolves-prod-ts-node" typescript 'versions = ["node-24"]' "" \
  "ghcr.io/vergil-project/prod-ts-node:24"
mismatch_case "cpp-caller-suffix-cpp-fails" cpp 'versions = ["clang-20"]' cpp \
  "container-suffix 'cpp' does not match"
mismatch_case "cpp-caller-suffix-non-primary-family-fails" cpp \
  'versions = ["clang-20", "gcc-14"]' cpp-gcc \
  "container-suffix 'cpp-gcc' does not match"
mismatch_case "python-caller-suffix-without-language-fails" "" 'versions = ["latest"]' python \
  "container-suffix 'python' does not match"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
