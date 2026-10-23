#!/usr/bin/env bash
#
# Test that cd-release.yml runs its release job on the resolver's primary
# container tag, not on a caller input (issue #1017, epic
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
#     and exports its primary-container-tag; `release` needs `setup`, refuses
#     to run without it, and takes its image tag (and its validate-inputs tag)
#     from it; the deprecated `container-tag` input defaults to empty and is
#     read only by the step that warns about it; no other workflow job builds
#     its image from a caller's `container-tag`.
#   * resolution — for a fixture repo, the release job's `container:`
#     expression, filled in with the setup action's derive.sh outputs and a
#     caller that passes no tag, names the image whose tag is
#     `vrg-ci-resolve`'s primary-container-tag.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
cd_release_yml="${repo_root}/.github/workflows/cd-release.yml"
workflows="${repo_root}/.github/workflows"
derive_sh="${repo_root}/actions/shared/setup/vergil/derive.sh"
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
  case "$image" in
    *':${{ needs.setup.outputs.primary-container-tag }}') ;;
    *)
      fail_case "$name" "release container does not end in the setup job's tag: $image"
      return 0
      ;;
  esac
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

# render_release_image <derive output file> <language> — fill in the release
# job's container expression for a caller that passes only `language`.
render_release_image() {
  local tag image
  tag="$(sed -n 's/^primary-container-tag=//p' "$1")"
  image="$(q '.jobs.release.container')"
  image="${image//"\${{ inputs.container-prefix || 'prod' }}"/prod}"
  image="${image//"\${{ inputs.container-suffix || inputs.language || 'base' }}"/${2:-base}}"
  image="${image//"\${{ needs.setup.outputs.primary-container-tag }}"/$tag}"
  printf '%s' "$image"
}

# resolve_case <name> <language|""> <[ci] lines> <want image>
resolve_case() {
  local name="$1" lang="$2" ci="$3" want="$4" dir so image direct
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
    return 0
  fi
  direct="$(VRG_VERSION_WINDOW="$window" vrg-ci-resolve --format json --repo-root "$dir" |
    jq -r '."primary-container-tag"')"
  image="$(render_release_image "$so" "$lang")"
  rm -rf "$dir" "$so"
  expect "$name" "image" "$image" "$want" || return 0
  expect "$name" "image tag vs vrg-ci-resolve" "${image##*:}" "$direct" || return 0
  pass_case "$name"
}

case_setup_job
case_release_uses_setup
case_deprecated_input
case_no_caller_tag_images
resolve_case "python-library-resolves-primary" python "" \
  "ghcr.io/vergil-project/prod-python:3.15"
resolve_case "python-primary-override" python 'primary-version = "3.14"' \
  "ghcr.io/vergil-project/prod-python:3.14"
resolve_case "no-language-resolves-latest" "" 'versions = ["latest"]' \
  "ghcr.io/vergil-project/prod-base:latest"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
