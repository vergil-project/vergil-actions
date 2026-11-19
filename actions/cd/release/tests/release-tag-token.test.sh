#!/usr/bin/env bash
#
# Test that release tags are pushed only with the automation App's
# installation token, never the checkout's GITHUB_TOKEN, and that a release
# without the App secrets fails before anything is published or tagged with
# an error naming them (vergil-project/vergil-actions#1315, epic
# vergil-project/.github#1350).
#
# Framework-free and developer-runnable: `bash release-tag-token.test.sh`.
# CI runs it from .github/workflows/smoke-cd-release.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners). No case touches
# the network. That push-tag.sh sends the App token and only that token is
# tag-and-release/tests/push-tag.test.sh's job; that a live release's tag is
# created by the App identity is checked by the release that follows this
# change (the epic's Task 2ad).
#
# Cases:
#   * tag-and-release requires its tag-token input, fails before tagging
#     when it is empty, and pushes every tag through push-tag.sh with
#     TAG_TOKEN set from it; no step runs `git push` itself, and only the
#     GitHub Release step uses github.token;
#   * cd-release's release job checks both App secrets, then mints a token
#     scoped to this repository with Contents write only, before the
#     evidence gate, the registry publish and the tag; it passes that token
#     as tag-token; no step of the workflow runs `git push`;
#   * the secrets check, run as written, fails naming each missing secret
#     and passes when both are set;
#   * vergil-actions' own cd.yml passes its App token as tag-token.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
action_yml="${repo_root}/actions/cd/release/tag-and-release/action.yml"
cd_release_yml="${repo_root}/.github/workflows/cd-release.yml"
cd_yml="${repo_root}/.github/workflows/cd.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'release-tag-token.test.sh needs yq on PATH\n' >&2
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

# expect <case> <what> <got> <want> — record a mismatch; returns 1 on one.
expect() {
  if [ "$3" != "$4" ]; then
    fail_case "$1" "$2: expected '$4', got '$3'"
    return 1
  fi
}

# step_index <file> <steps path> <name> — the index of the named step, or
# empty when there is none.
step_index() {
  yq -r "$2 | to_entries | .[] | select(.value.name == \"$3\") | .key" "$1"
}

# shellcheck disable=SC2016 # literal GitHub Actions expressions throughout
token_expr='${{ inputs.tag-token }}'

case_action_pushes_with_tag_token() {
  local name="tag-and-release-pushes-only-with-tag-token" n i run tok
  expect "$name" "tag-token required" \
    "$(yq -r '.inputs."tag-token".required' "$action_yml")" "true" || return 0
  expect "$name" "tag-token default" \
    "$(yq -r '.inputs."tag-token".default // "none"' "$action_yml")" "none" || return 0
  # No step pushes with git directly.
  n="$(yq -r '[.runs.steps[] | select((.run // "") | test("git push"))] | length' "$action_yml")"
  expect "$name" "steps running git push directly" "$n" "0" || return 0
  # The three tag pushes (release tag, develop tag, resync) go through
  # push-tag.sh, each with TAG_TOKEN from the input.
  n="$(yq -r '[.runs.steps[] | select((.run // "") | test("push-tag\.sh"))] | length' "$action_yml")"
  expect "$name" "steps calling push-tag.sh" "$n" "3" || return 0
  for i in $(yq -r '.runs.steps | to_entries | .[] | select((.value.run // "") | test("push-tag\.sh")) | .key' "$action_yml"); do
    tok="$(yq -r ".runs.steps[$i].env.TAG_TOKEN" "$action_yml")"
    expect "$name" "step $i TAG_TOKEN" "$tok" "$token_expr" || return 0
    run="$(yq -r ".runs.steps[$i].run" "$action_yml")"
    case "$run" in
      *'bash "${GITHUB_ACTION_PATH}/push-tag.sh" '*) ;;
      *)
        fail_case "$name" "step $i does not run the action's own push-tag.sh: ${run}"
        return 0
        ;;
    esac
  done
  # github.token appears once: the Release step's GH_TOKEN.
  n="$(grep -c 'github\.token' "$action_yml" || true)"
  expect "$name" "github.token uses" "$n" "1" || return 0
  # shellcheck disable=SC2016
  expect "$name" "Release GH_TOKEN" \
    "$(yq -r '.runs.steps[] | select(.name == "Create GitHub Release") | .env.GH_TOKEN' "$action_yml")" \
    '${{ github.token }}' || return 0
  pass_case "$name"
}

case_action_refuses_empty_token_before_tagging() {
  local name="tag-and-release-refuses-empty-token-before-tagging" req tag run rc out
  req="$(step_index "$action_yml" .runs.steps "Require the tag token")"
  tag="$(step_index "$action_yml" .runs.steps "Create annotated tag")"
  if [ -z "$req" ] || [ -z "$tag" ] || [ "$req" -ge "$tag" ]; then
    fail_case "$name" "'Require the tag token' (${req:-none}) is not before 'Create annotated tag' (${tag:-none})"
    return 0
  fi
  expect "$name" "check env" "$(yq -r ".runs.steps[$req].env.TAG_TOKEN" "$action_yml")" \
    "$token_expr" || return 0
  run="$(yq -r ".runs.steps[$req].run" "$action_yml")"
  set +e
  out="$(TAG_TOKEN="" bash --noprofile --norc -eo pipefail -c "$run" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the check passed an empty token"
    return 0
  fi
  case "$out" in
    *"::error::"*"tag-token input is empty"*) ;;
    *)
      fail_case "$name" "the error does not name the tag-token input: ${out}"
      return 0
      ;;
  esac
  set +e
  out="$(TAG_TOKEN="x" bash --noprofile --norc -eo pipefail -c "$run" 2>&1)"
  rc=$?
  set -e
  expect "$name" "check with a token" "$rc" "0" || return 0
  pass_case "$name"
}

case_cd_release_mints_before_publish() {
  local name="cd-release-checks-and-mints-before-publish-and-tag" s q
  local -A at=()
  for s in "Check if tag already exists" "Require the automation App secrets" \
    "Mint release tag token" "CI evidence gate (pre-publish)" "Build and publish" \
    "Tag and release"; do
    at["$s"]="$(step_index "$cd_release_yml" .jobs.release.steps "$s")"
    if [ -z "${at[$s]}" ]; then
      fail_case "$name" "the release job has no step named '$s'"
      return 0
    fi
  done
  if ! [ "${at["Check if tag already exists"]}" -lt "${at["Require the automation App secrets"]}" ] ||
    ! [ "${at["Require the automation App secrets"]}" -lt "${at["Mint release tag token"]}" ] ||
    ! [ "${at["Mint release tag token"]}" -lt "${at["CI evidence gate (pre-publish)"]}" ] ||
    ! [ "${at["Mint release tag token"]}" -lt "${at["Build and publish"]}" ] ||
    ! [ "${at["Mint release tag token"]}" -lt "${at["Tag and release"]}" ]; then
    fail_case "$name" "the App secrets check and mint are not before the evidence gate, publish and tag"
    return 0
  fi
  q() { yq -r ".jobs.release.steps[${at[$1]}] | $2" "$cd_release_yml"; }
  # shellcheck disable=SC2016
  {
    expect "$name" "check if" "$(q "Require the automation App secrets" .if)" \
      "steps.tag_check.outputs.exists == 'false'" || return 0
    expect "$name" "check APP_CLIENT_ID" "$(q "Require the automation App secrets" .env.APP_CLIENT_ID)" \
      '${{ secrets.APP_CLIENT_ID }}' || return 0
    expect "$name" "check APP_PRIVATE_KEY" "$(q "Require the automation App secrets" .env.APP_PRIVATE_KEY)" \
      '${{ secrets.APP_PRIVATE_KEY }}' || return 0
    expect "$name" "mint id" "$(q "Mint release tag token" .id)" "tag_token" || return 0
    expect "$name" "mint if" "$(q "Mint release tag token" .if)" \
      "steps.tag_check.outputs.exists == 'false'" || return 0
    expect "$name" "mint uses" "$(q "Mint release tag token" .uses)" \
      "actions/create-github-app-token@v3" || return 0
    expect "$name" "mint continue-on-error" \
      "$(q "Mint release tag token" '."continue-on-error" // "absent"')" "absent" || return 0
    expect "$name" "mint app-id" "$(q "Mint release tag token" '.with."app-id"')" \
      '${{ secrets.APP_CLIENT_ID }}' || return 0
    expect "$name" "mint private-key" "$(q "Mint release tag token" '.with."private-key"')" \
      '${{ secrets.APP_PRIVATE_KEY }}' || return 0
    expect "$name" "mint owner" "$(q "Mint release tag token" .with.owner)" \
      '${{ github.repository_owner }}' || return 0
    expect "$name" "mint repositories" "$(q "Mint release tag token" .with.repositories)" \
      '${{ github.event.repository.name }}' || return 0
    expect "$name" "mint permissions" \
      "$(q "Mint release tag token" '[.with | to_entries | .[] | select(.key | test("^permission-")) | .key + "=" + .value] | join(",")')" \
      "permission-contents=write" || return 0
    expect "$name" "tag-token passed" "$(q "Tag and release" '.with."tag-token"')" \
      '${{ steps.tag_token.outputs.token }}' || return 0
  }
  expect "$name" "APP_CLIENT_ID declared optional" \
    "$(yq -r '.on.workflow_call.secrets.APP_CLIENT_ID.required' "$cd_release_yml")" "false" || return 0
  expect "$name" "APP_PRIVATE_KEY declared optional" \
    "$(yq -r '.on.workflow_call.secrets.APP_PRIVATE_KEY.required' "$cd_release_yml")" "false" || return 0
  expect "$name" "steps running git push" \
    "$(yq -r '[.jobs[].steps[]? | select((.run // "") | test("git push"))] | length' "$cd_release_yml")" \
    "0" || return 0
  pass_case "$name"
}

# run_secrets_check <client id> <private key> — run the release job's
# secrets check as GitHub runs a bash step. Sets rc and out.
run_secrets_check() {
  local run
  run="$(yq -r '.jobs.release.steps[] | select(.name == "Require the automation App secrets") | .run' \
    "$cd_release_yml")"
  set +e
  out="$(APP_CLIENT_ID="$1" APP_PRIVATE_KEY="$2" bash --noprofile --norc -eo pipefail -c "$run" 2>&1)"
  rc=$?
  set -e
}

case_secrets_check_names_missing() {
  local name="secrets-check-names-each-missing-secret"
  run_secrets_check "" ""
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the check passed with neither secret"
    return 0
  fi
  case "$out" in
    *"::error::"*"did not pass APP_CLIENT_ID APP_PRIVATE_KEY."*"Nothing has been published or tagged."*) ;;
    *)
      fail_case "$name" "with neither secret, the error does not name both: ${out}"
      return 0
      ;;
  esac
  run_secrets_check "client-id" ""
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the check passed without APP_PRIVATE_KEY"
    return 0
  fi
  case "$out" in
    *"did not pass APP_PRIVATE_KEY."*) ;;
    *)
      fail_case "$name" "without the key, the error does not name only APP_PRIVATE_KEY: ${out}"
      return 0
      ;;
  esac
  run_secrets_check "" "key"
  case "$rc:$out" in
    0:*)
      fail_case "$name" "the check passed without APP_CLIENT_ID"
      return 0
      ;;
    *"did not pass APP_CLIENT_ID."*) ;;
    *)
      fail_case "$name" "without the client ID, the error does not name only APP_CLIENT_ID: ${out}"
      return 0
      ;;
  esac
  run_secrets_check "client-id" "key"
  expect "$name" "check with both secrets" "$rc:$out" "0:" || return 0
  pass_case "$name"
}

case_cd_yml_passes_app_token() {
  local name="vergil-actions-cd-passes-app-token"
  # shellcheck disable=SC2016
  expect "$name" "tag-token" \
    "$(yq -r '.jobs.release.steps[] | select(.name == "Tag and release") | .with."tag-token"' "$cd_yml")" \
    '${{ steps.app-token.outputs.token }}' || return 0
  expect "$name" "app-token step" \
    "$(yq -r '.jobs.release.steps[] | select(.id == "app-token") | .uses' "$cd_yml")" \
    "actions/create-github-app-token@v3" || return 0
  expect "$name" "steps running git push" \
    "$(yq -r '[.jobs[].steps[]? | select((.run // "") | test("git push"))] | length' "$cd_yml")" \
    "0" || return 0
  pass_case "$name"
}

case_action_pushes_with_tag_token
case_action_refuses_empty_token_before_tagging
case_cd_release_mints_before_publish
case_secrets_check_names_missing
case_cd_yml_passes_app_token

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
