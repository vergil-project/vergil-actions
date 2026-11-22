#!/usr/bin/env bash
#
# Test the trusted-authors-check job of ops-github-config.yml (issue #1353,
# epic vergil-project/.github#1467, spec §5.1a).
#
# The daily config audit checks the org Actions variables VRG_TRUSTED_AUTHORS
# and VRG_AUTOMATION_APP, and every repository-level variable of either name,
# with `vrg-trusted-authors check`, as the org automation App. It uploads the
# values check read as the trusted-authors-values artifact, on success and on
# failure, for hoshin start to compare with the host configuration.
#
# Framework-free and developer-runnable: `bash trusted-authors-check.test.sh`.
# CI runs it from .github/workflows/smoke-setup-vergil.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, checked on the trusted-authors-check job:
#   * exactly one step runs `vrg-trusted-authors check`, with
#     `--org "$ORG"`, ORG from `${{ github.repository_owner }}`, and
#     `--values-out <file>`;
#   * that step runs as the automation App: VRG_AUTOMATION_APP from
#     `${{ vars.VRG_AUTOMATION_APP }}` and GH_TOKEN from the token of an
#     earlier create-github-app-token step;
#   * that token step is scoped to the org's installation (`owner:
#     ${{ github.repository_owner }}`, no `repositories`) and asks for
#     exactly organization Variables, repository Variables and Metadata,
#     each read-only;
#   * a later step uploads <file> with actions/upload-artifact as the
#     artifact trusted-authors-values, with `if: always()`.
# Fixture workflows check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
ops="${repo_root}/.github/workflows/ops-github-config.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'trusted-authors-check.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$ops" ]; then
  printf 'trusted-authors-check.test.sh: missing %s\n' "$ops" >&2
  exit 1
fi

# shellcheck disable=SC2016 # literal GitHub Actions expressions
owner_expr='${{ github.repository_owner }}'
# shellcheck disable=SC2016 # a literal GitHub Actions expression
automation_expr='${{ vars.VRG_AUTOMATION_APP }}'
expected_permissions='permission-actions-variables=read
permission-metadata=read
permission-organization-actions-variables=read'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

# violations <workflow file> — print one line per rule the workflow's
# trusted-authors-check job breaks, nothing when it keeps them all.
violations() {
  local wf="$1" job='.jobs."trusted-authors-check"' count idx run token ref
  local ref_idx uses permissions values_out up_idx
  if [ "$(yq -r "${job} | type" "$wf")" != "!!map" ]; then
    printf 'no trusted-authors-check job\n'
    return 0
  fi
  count="$(yq -r "[${job}.steps[] | select((.run // \"\") | test(\"vrg-trusted-authors check\"))] | length" "$wf")"
  if [ "$count" != "1" ]; then
    printf 'trusted-authors-check has %s steps running vrg-trusted-authors check, not 1\n' "$count"
    return 0
  fi
  idx="$(yq -r "${job}.steps | to_entries | .[]
    | select((.value.run // \"\") | test(\"vrg-trusted-authors check\")) | .key" "$wf")"
  run="$(yq -r "${job}.steps[${idx}].run" "$wf")"
  # shellcheck disable=SC2016 # the literal argument the step must pass
  case "$run" in
    *'--org "$ORG"'*) ;;
    *) printf 'the check step does not pass --org "$ORG"\n' ;;
  esac
  if [ "$(yq -r "${job}.steps[${idx}].env.ORG // \"<unset>\"" "$wf")" != "$owner_expr" ]; then
    printf 'the check step does not take ORG from %s\n' "$owner_expr"
  fi
  if [[ "$run" =~ --values-out[[:space:]]+([^[:space:]]+) ]]; then
    values_out="${BASH_REMATCH[1]}"
  else
    printf 'the check step does not pass --values-out\n'
    values_out="<unset>"
  fi
  if [ "$(yq -r "${job}.steps[${idx}].env.VRG_AUTOMATION_APP // \"<unset>\"" "$wf")" != "$automation_expr" ]; then
    printf 'the check step does not take VRG_AUTOMATION_APP from %s\n' "$automation_expr"
  fi
  token="$(yq -r "${job}.steps[${idx}].env.GH_TOKEN // \"<unset>\"" "$wf")"
  if ! [[ "$token" =~ ^\$\{\{\ steps\.([A-Za-z0-9_-]+)\.outputs\.token\ \}\}$ ]]; then
    printf 'the check step does not take GH_TOKEN from a token step: %s\n' "$token"
  else
    ref="${BASH_REMATCH[1]}"
    ref_idx="$(yq -r "${job}.steps | to_entries | .[]
      | select(.value.id == \"${ref}\") | .key" "$wf")"
    if [ -z "$ref_idx" ] || [ "$ref_idx" -ge "$idx" ]; then
      printf 'GH_TOKEN names no earlier step %s\n' "$ref"
    else
      uses="$(yq -r "${job}.steps[${ref_idx}].uses // \"\"" "$wf")"
      case "$uses" in
        actions/create-github-app-token@*) ;;
        *) printf 'token step %s is not actions/create-github-app-token: %s\n' "$ref" "$uses" ;;
      esac
      if [ "$(yq -r "${job}.steps[${ref_idx}].with.owner // \"<unset>\"" "$wf")" != "$owner_expr" ]; then
        printf 'token step %s is not scoped to owner %s\n' "$ref" "$owner_expr"
      fi
      if [ "$(yq -r "${job}.steps[${ref_idx}].with | has(\"repositories\")" "$wf")" = "true" ]; then
        printf 'token step %s names repositories\n' "$ref"
      fi
      permissions="$(yq -r "${job}.steps[${ref_idx}].with | to_entries | .[]
        | select(.key | test(\"^permission-\")) | .key + \"=\" + .value" "$wf" | LC_ALL=C sort)"
      if [ "$permissions" != "$expected_permissions" ]; then
        printf 'token step %s permissions are not read-only Variables and Metadata: %s\n' \
          "$ref" "$(tr '\n' ' ' <<<"$permissions")"
      fi
    fi
  fi
  up_idx="$(yq -r "${job}.steps | to_entries | .[]
    | select((.value.uses // \"\") | test(\"^actions/upload-artifact@\"))
    | select(.value.with.name == \"trusted-authors-values\") | .key" "$wf" | head -n 1)"
  if [ -z "$up_idx" ]; then
    printf 'no step uploads the trusted-authors-values artifact\n'
    return 0
  fi
  if [ "$up_idx" -le "$idx" ]; then
    printf 'the upload step does not follow the check step\n'
  fi
  if [ "$(yq -r "${job}.steps[${up_idx}].with.path // \"<unset>\"" "$wf")" != "$values_out" ]; then
    printf 'the upload step does not upload the --values-out file %s\n' "$values_out"
  fi
  if [ "$(yq -r "${job}.steps[${up_idx}].if // \"<unset>\"" "$wf")" != "always()" ]; then
    printf 'the upload step does not run with if: always()\n'
  fi
}

# expect_clean <case> <workflow file>
expect_clean() {
  local out
  out="$(violations "$2")"
  if [ -n "$out" ]; then
    fail_case "$1" "$out"
    return 0
  fi
  pass_case "$1"
}

# expect_caught <case> <workflow file> <substring of the expected violation>
expect_caught() {
  local out
  out="$(violations "$2")"
  case "$out" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$3', got: ${out:-<none>}" ;;
  esac
}

# good_fixture <file> — a job that keeps every rule; each broken fixture
# changes one thing in it with yq.
good_fixture() {
  cat >"$1" <<'YAML'
jobs:
  trusted-authors-check:
    steps:
      - id: app-token
        uses: actions/create-github-app-token@v3
        with:
          app-id: ${{ secrets.APP_CLIENT_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          permission-organization-actions-variables: read
          permission-actions-variables: read
          permission-metadata: read
      - uses: ./actions/shared/setup/vergil
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
          ORG: ${{ github.repository_owner }}
        run: vrg-trusted-authors check --org "$ORG" --values-out values.json
      - if: always()
        uses: actions/upload-artifact@v7
        with:
          name: trusted-authors-values
          path: values.json
YAML
}

# broken <case> <yq update> <expected violation substring>
broken() {
  local file="${tmp}/$1.yml"
  good_fixture "$file"
  yq -i "$2" "$file"
  expect_caught "$1" "$file" "$3"
}

case_real_workflow() {
  expect_clean "ops-github-config-trusted-authors-check" "$ops"
}

case_fixtures() {
  local job='.jobs."trusted-authors-check"'
  good_fixture "${tmp}/good.yml"
  expect_clean "fixture-good-is-clean" "${tmp}/good.yml"

  broken "fixture-no-job-caught" 'del(.jobs."trusted-authors-check")' \
    "no trusted-authors-check job"
  broken "fixture-no-check-step-caught" "del(${job}.steps[2])" \
    "0 steps running vrg-trusted-authors check"
  broken "fixture-no-org-caught" "${job}.steps[2].run = \"vrg-trusted-authors check --values-out values.json\"" \
    'does not pass --org "$ORG"'
  broken "fixture-no-values-out-caught" "${job}.steps[2].run = \"vrg-trusted-authors check --org \\\"\$ORG\\\"\"" \
    "does not pass --values-out"
  broken "fixture-no-automation-app-caught" "del(${job}.steps[2].env.VRG_AUTOMATION_APP)" \
    "does not take VRG_AUTOMATION_APP"
  broken "fixture-github-token-caught" "${job}.steps[2].env.GH_TOKEN = \"\${{ github.token }}\"" \
    "does not take GH_TOKEN from a token step"
  broken "fixture-later-token-step-caught" "${job}.steps |= [.[1], .[2], .[0], .[3]]" \
    "GH_TOKEN names no earlier step app-token"
  broken "fixture-repo-scoped-token-caught" "del(${job}.steps[0].with.owner)" \
    "is not scoped to owner"
  broken "fixture-repositories-caught" "${job}.steps[0].with.repositories = \"one\"" \
    "names repositories"
  broken "fixture-write-permission-caught" "${job}.steps[0].with.permission-actions-variables = \"write\"" \
    "permissions are not read-only Variables and Metadata"
  broken "fixture-extra-permission-caught" "${job}.steps[0].with.permission-contents = \"read\"" \
    "permissions are not read-only Variables and Metadata"
  broken "fixture-no-permissions-caught" \
    "${job}.steps[0].with |= with_entries(select(.key | test(\"^permission-\") | not))" \
    "permissions are not read-only Variables and Metadata"
  broken "fixture-no-upload-caught" "del(${job}.steps[3])" \
    "no step uploads the trusted-authors-values artifact"
  broken "fixture-upload-not-always-caught" "del(${job}.steps[3].if)" \
    "does not run with if: always()"
  broken "fixture-upload-wrong-path-caught" "${job}.steps[3].with.path = \"other.json\"" \
    "does not upload the --values-out file values.json"
  broken "fixture-upload-before-check-caught" "${job}.steps |= [.[0], .[1], .[3], .[2]]" \
    "does not follow the check step"
}

case_real_workflow
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
