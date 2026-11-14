#!/usr/bin/env bash
#
# Test where the workflows set VRG_AUTOMATION_APP (issue #1192).
#
# VRG_AUTOMATION_APP says the process holds the org automation App's
# installation token (epic vergil-project/.github#1064, spec §6.1): every
# vrg-* command that sees it verifies GH_TOKEN against the App it names and
# fails loudly when it cannot. A process that sets it without that token
# fails, by design. v2.1.71 set it on the whole github-config job of
# ops-github-config.yml, so it reached the setup action's `vrg-whoami --mode`
# check, which runs before any step has GH_TOKEN, and every run failed.
#
# Framework-free and developer-runnable: `bash automation-env.test.sh`. CI
# runs it from .github/workflows/smoke-setup-vergil.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners) and touches no
# network.
#
# The rules, checked on every workflow in .github/workflows:
#   * no workflow-level or job-level `env` sets VRG_AUTOMATION_APP;
#   * a step that sets it takes it from `${{ vars.VRG_AUTOMATION_APP }}` and
#     sets GH_TOKEN, in the same `env`, from `${{ steps.<id>.outputs.token }}`
#     of an earlier step of its job.
# For ops-github-config.yml's github-config job:
#   * the step that runs `vrg-github-repo-config update` sets it;
#   * the first step, before the app-token step, reads the variable as
#     AUTOMATION_APP and fails on an empty one.
# Fixture workflows check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"
ops="${workflows}/ops-github-config.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'automation-env.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$ops" ]; then
  printf 'automation-env.test.sh: missing %s\n' "$ops" >&2
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

# violations <workflow file> — print one line per rule the workflow breaks,
# nothing when it keeps them all.
violations() {
  local wf="$1" job idx has value token ref ref_idx
  if [ "$(yq -r '(.env // {}) | has("VRG_AUTOMATION_APP")' "$wf")" = "true" ]; then
    printf 'workflow env sets VRG_AUTOMATION_APP\n'
  fi
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    printf '%s: job env sets VRG_AUTOMATION_APP\n' "$job"
  done < <(yq -r '(.jobs // {}) | to_entries | .[]
    | select((.value.env // {}) | has("VRG_AUTOMATION_APP")) | .key' "$wf")
  # shellcheck disable=SC2016 # $j in the yq query below is a yq variable
  while IFS=$'\t' read -r job idx has value token; do
    [ "$has" = "true" ] || continue
    # shellcheck disable=SC2016 # a literal GitHub Actions expression
    if [ "$value" != '${{ vars.VRG_AUTOMATION_APP }}' ]; then
      printf '%s step %s: VRG_AUTOMATION_APP is not ${{ vars.VRG_AUTOMATION_APP }}: %s\n' \
        "$job" "$idx" "$value"
    fi
    if ! [[ "$token" =~ ^\$\{\{\ steps\.([A-Za-z0-9_-]+)\.outputs\.token\ \}\}$ ]]; then
      printf '%s step %s: sets VRG_AUTOMATION_APP without GH_TOKEN from a token step: %s\n' \
        "$job" "$idx" "${token:-<unset>}"
      continue
    fi
    ref="${BASH_REMATCH[1]}"
    ref_idx="$(yq -r ".jobs.\"${job}\".steps | to_entries | .[]
      | select(.value.id == \"${ref}\") | .key" "$wf")"
    if [ -z "$ref_idx" ] || [ "$ref_idx" -ge "$idx" ]; then
      printf '%s step %s: GH_TOKEN names no earlier step %s\n' "$job" "$idx" "$ref"
    fi
  done < <(yq -r '(.jobs // {}) | to_entries | .[] | .key as $j
    | (.value.steps // []) | to_entries | .[]
    | [$j, .key,
       ((.value.env // {}) | has("VRG_AUTOMATION_APP")),
       ((.value.env // {}).VRG_AUTOMATION_APP // ""),
       ((.value.env // {}).GH_TOKEN // "")] | @tsv' "$wf")
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

case_real_workflows() {
  local wf
  for wf in "$workflows"/*.yml; do
    expect_clean "$(basename "$wf")-automation-env-scoped-to-token-steps" "$wf"
  done
}

case_update_step_is_automation() {
  local name="ops-github-config-update-step-sets-VRG_AUTOMATION_APP" sel
  sel='.jobs."github-config".steps[] | select((.run // "") | test("vrg-github-repo-config update"))'
  if [ "$(yq -r "[${sel}] | length" "$ops")" != "1" ]; then
    fail_case "$name" "github-config has no single step running vrg-github-repo-config update"
    return 0
  fi
  if [ "$(yq -r "${sel} | (.env // {}) | has(\"VRG_AUTOMATION_APP\")" "$ops")" != "true" ]; then
    fail_case "$name" "the update step does not set VRG_AUTOMATION_APP"
    return 0
  fi
  pass_case "$name"
}

case_precheck_reads_variable() {
  local name="ops-github-config-precheck-before-token" first token_idx run
  first='.jobs."github-config".steps[0]'
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$(yq -r "${first}.env.AUTOMATION_APP" "$ops")" != '${{ vars.VRG_AUTOMATION_APP }}' ]; then
    fail_case "$name" "the first step does not read vars.VRG_AUTOMATION_APP as AUTOMATION_APP"
    return 0
  fi
  run="$(yq -r "${first}.run" "$ops")"
  # shellcheck disable=SC2016 # the literal shell test the step must contain
  case "$run" in
    *'[ -z "${AUTOMATION_APP}" ]'*) ;;
    *)
      fail_case "$name" "the first step does not fail on an empty AUTOMATION_APP"
      return 0
      ;;
  esac
  token_idx="$(yq -r '.jobs."github-config".steps | to_entries | .[]
    | select(.value.id == "app-token") | .key' "$ops")"
  if [ -z "$token_idx" ] || [ "$token_idx" -lt 1 ]; then
    fail_case "$name" "the app-token step does not follow the first step"
    return 0
  fi
  pass_case "$name"
}

case_fixtures() {
  cat >"${tmp}/good.yml" <<'YAML'
jobs:
  sync:
    steps:
      - name: Require the variable
        env:
          AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
        run: test -n "${AUTOMATION_APP}"
      - id: app-token
        uses: actions/create-github-app-token@v3
      - uses: ./actions/shared/setup/vergil
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
        run: vrg-github-repo-config update
YAML
  expect_clean "fixture-token-step-is-clean" "${tmp}/good.yml"

  # The v2.1.71 shape: the job env reaches the setup action's vrg-whoami.
  cat >"${tmp}/job-env.yml" <<'YAML'
jobs:
  sync:
    env:
      VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
    steps:
      - id: app-token
        uses: actions/create-github-app-token@v3
      - uses: ./actions/shared/setup/vergil
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: vrg-github-repo-config update
YAML
  expect_caught "fixture-job-env-caught" "${tmp}/job-env.yml" \
    "sync: job env sets VRG_AUTOMATION_APP"

  cat >"${tmp}/workflow-env.yml" <<'YAML'
env:
  VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
jobs:
  sync:
    steps:
      - run: true
YAML
  expect_caught "fixture-workflow-env-caught" "${tmp}/workflow-env.yml" \
    "workflow env sets VRG_AUTOMATION_APP"

  cat >"${tmp}/no-token.yml" <<'YAML'
jobs:
  sync:
    steps:
      - uses: ./actions/shared/setup/vergil
        env:
          VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
YAML
  expect_caught "fixture-step-without-token-caught" "${tmp}/no-token.yml" \
    "sync step 0: sets VRG_AUTOMATION_APP without GH_TOKEN from a token step: <unset>"

  cat >"${tmp}/github-token.yml" <<'YAML'
jobs:
  sync:
    steps:
      - env:
          GH_TOKEN: ${{ github.token }}
          VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
        run: vrg-github-repo-config update
YAML
  expect_caught "fixture-github-token-caught" "${tmp}/github-token.yml" \
    "without GH_TOKEN from a token step"

  cat >"${tmp}/later-token.yml" <<'YAML'
jobs:
  sync:
    steps:
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          VRG_AUTOMATION_APP: ${{ vars.VRG_AUTOMATION_APP }}
        run: vrg-github-repo-config update
      - id: app-token
        uses: actions/create-github-app-token@v3
YAML
  expect_caught "fixture-later-token-step-caught" "${tmp}/later-token.yml" \
    "GH_TOKEN names no earlier step app-token"

  cat >"${tmp}/literal-slug.yml" <<'YAML'
jobs:
  sync:
    steps:
      - id: app-token
        uses: actions/create-github-app-token@v3
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          VRG_AUTOMATION_APP: some-org-automation
        run: vrg-github-repo-config update
YAML
  expect_caught "fixture-literal-slug-caught" "${tmp}/literal-slug.yml" \
    "is not \${{ vars.VRG_AUTOMATION_APP }}: some-org-automation"
}

case_real_workflows
case_update_step_is_automation
case_precheck_reads_variable
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
