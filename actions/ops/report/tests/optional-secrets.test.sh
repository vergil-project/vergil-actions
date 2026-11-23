#!/usr/bin/env bash
#
# Test the optional App secrets of the workflows that gain reporting (issue
# #1361, epic vergil-project/.github#1494, spec §5.6).
#
# Callers pin the moving @v2.1 tag, so a release that gave cd-docs.yml,
# cd-docs-refresh.yml or publish-index.yml a reporting job needing secrets
# they do not pass would turn every caller's run red. The three workflows
# therefore declare APP_CLIENT_ID and APP_PRIVATE_KEY as optional first, and
# every caller passes them before the reporting release. cd-docs-refresh.yml
# nests cd-docs.yml@develop, which resolves to develop's copy until the
# release freezes it, so its call already turns cd-docs.yml's later reporting
# job off (`report: false`; the refresh reports as docs-refresh) and forwards
# both secrets.
#
# Framework-free and developer-runnable: `bash optional-secrets.test.sh`.
# CI runs it from .github/workflows/smoke-ops-report.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules:
#   * cd-docs.yml, cd-docs-refresh.yml and publish-index.yml declare
#     on.workflow_call.secrets APP_CLIENT_ID and APP_PRIVATE_KEY, each
#     `required: false`;
#   * cd-docs.yml declares a boolean input `report`, default true;
#   * cd-docs-refresh.yml's call of cd-docs.yml passes `report: false` and
#     each secret from the secret of the same name.
# Fixture workflows check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"

if ! command -v yq >/dev/null 2>&1; then
  printf 'optional-secrets.test.sh needs yq on PATH\n' >&2
  exit 1
fi

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

# secret_violations <workflow file> — one line per missing or required
# App secret declaration.
secret_violations() {
  local wf="$1" name has required
  if [ ! -f "$wf" ]; then
    printf 'missing %s\n' "$wf"
    return 0
  fi
  for name in APP_CLIENT_ID APP_PRIVATE_KEY; do
    has="$(yq -r "(.on.workflow_call.secrets // {}) | has(\"${name}\")" "$wf")"
    if [ "$has" != "true" ]; then
      printf 'does not declare the %s secret\n' "$name"
      continue
    fi
    required="$(yq -r ".on.workflow_call.secrets.${name}.required" "$wf")"
    if [ "$required" != "false" ]; then
      printf 'declares %s with required: %s, not false\n' "$name" "$required"
    fi
  done
}

# report_input_violations <workflow file> — cd-docs.yml's `report` input.
report_input_violations() {
  local wf="$1" kind default
  kind="$(yq -r '.on.workflow_call.inputs.report.type // "<unset>"' "$wf")"
  default="$(yq -r '.on.workflow_call.inputs.report.default' "$wf")"
  if [ "$kind" != "boolean" ] || [ "$default" != "true" ]; then
    printf 'does not declare a boolean report input defaulting to true (type %s, default %s)\n' \
      "$kind" "$default"
  fi
}

# nested_call_violations <workflow file> — cd-docs-refresh.yml's call of
# cd-docs.yml.
nested_call_violations() {
  local wf="$1" jobs job report name value
  jobs="$(yq -r '(.jobs // {}) | to_entries | .[]
    | select((.value.uses // "") | test("/cd-docs\.yml@")) | .key' "$wf")"
  if [ -z "$jobs" ]; then
    printf 'has no job calling cd-docs.yml\n'
    return 0
  fi
  while IFS= read -r job; do
    report="$(yq -r ".jobs.\"${job}\".with.report" "$wf")"
    if [ "$report" != "false" ]; then
      printf '%s: does not pass report: false (%s)\n' "$job" "$report"
    fi
    for name in APP_CLIENT_ID APP_PRIVATE_KEY; do
      value="$(yq -r ".jobs.\"${job}\".secrets | select(tag == \"!!map\") | .${name} // \"<unset>\"" "$wf")"
      if [ "$value" != "\${{ secrets.${name} }}" ]; then
        printf '%s: does not forward %s: %s\n' "$job" "$name" "$value"
      fi
    done
  done <<<"$jobs"
}

# expect <case> <violations output> [<substring of the expected violation>]
# — clean when no substring is given, else caught.
expect() {
  if [ "$#" -eq 2 ]; then
    if [ -n "$2" ]; then
      fail_case "$1" "$2"
      return 0
    fi
    pass_case "$1"
    return 0
  fi
  case "$2" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$3', got: ${2:-<none>}" ;;
  esac
}

case_real_workflows() {
  local wf
  for wf in cd-docs.yml cd-docs-refresh.yml publish-index.yml; do
    expect "${wf}-declares-optional-app-secrets" "$(secret_violations "${workflows}/${wf}")"
  done
  expect "cd-docs.yml-declares-report-input" "$(report_input_violations "${workflows}/cd-docs.yml")"
  expect "cd-docs-refresh.yml-nested-call-reports-off-and-forwards-secrets" \
    "$(nested_call_violations "${workflows}/cd-docs-refresh.yml")"
}

case_fixtures() {
  cat >"${tmp}/none.yml" <<'YAML'
on:
  workflow_call: {}
YAML
  expect "fixture-no-secrets-caught" "$(secret_violations "${tmp}/none.yml")" \
    "does not declare the APP_CLIENT_ID secret"

  cat >"${tmp}/required.yml" <<'YAML'
on:
  workflow_call:
    secrets:
      APP_CLIENT_ID:
        required: false
      APP_PRIVATE_KEY:
        required: true
YAML
  expect "fixture-required-secret-caught" "$(secret_violations "${tmp}/required.yml")" \
    "declares APP_PRIVATE_KEY with required: true, not false"

  cat >"${tmp}/unstated.yml" <<'YAML'
on:
  workflow_call:
    secrets:
      APP_CLIENT_ID:
        required: false
      APP_PRIVATE_KEY: {}
YAML
  expect "fixture-unstated-required-caught" "$(secret_violations "${tmp}/unstated.yml")" \
    "declares APP_PRIVATE_KEY with required: null, not false"

  cat >"${tmp}/report-string.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      report:
        type: string
        default: "true"
YAML
  expect "fixture-report-not-boolean-caught" "$(report_input_violations "${tmp}/report-string.yml")" \
    "does not declare a boolean report input"

  cat >"${tmp}/report-off.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      report:
        type: boolean
        default: false
YAML
  expect "fixture-report-default-off-caught" "$(report_input_violations "${tmp}/report-off.yml")" \
    "does not declare a boolean report input defaulting to true (type boolean, default false)"

  cat >"${tmp}/nested-good.yml" <<'YAML'
jobs:
  refresh:
    uses: o/r/.github/workflows/cd-docs.yml@develop
    with:
      report: false
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
YAML
  expect "fixture-nested-call-is-clean" "$(nested_call_violations "${tmp}/nested-good.yml")"

  cat >"${tmp}/nested-reports.yml" <<'YAML'
jobs:
  refresh:
    uses: o/r/.github/workflows/cd-docs.yml@develop
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
YAML
  expect "fixture-nested-call-reporting-caught" "$(nested_call_violations "${tmp}/nested-reports.yml")" \
    "refresh: does not pass report: false (null)"

  cat >"${tmp}/nested-inherit.yml" <<'YAML'
jobs:
  refresh:
    uses: o/r/.github/workflows/cd-docs.yml@develop
    with:
      report: false
    secrets: inherit
YAML
  expect "fixture-nested-call-inherit-caught" "$(nested_call_violations "${tmp}/nested-inherit.yml")" \
    "refresh: does not forward APP_CLIENT_ID"

  cat >"${tmp}/nested-missing-key.yml" <<'YAML'
jobs:
  refresh:
    uses: o/r/.github/workflows/cd-docs.yml@develop
    with:
      report: false
    secrets:
      APP_CLIENT_ID: ${{ secrets.APP_CLIENT_ID }}
YAML
  expect "fixture-nested-call-missing-key-caught" "$(nested_call_violations "${tmp}/nested-missing-key.yml")" \
    "refresh: does not forward APP_PRIVATE_KEY: <unset>"
}

case_real_workflows
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
