#!/usr/bin/env bash
#
# Test the ops-report action's inputs, token and reporter step (issue #1361,
# epic vergil-project/.github#1494, spec §5.3).
#
# Framework-free and developer-runnable: `bash ops-report-inputs.test.sh`.
# CI runs it from .github/workflows/smoke-ops-report.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, checked on actions/ops/report/action.yml:
#   * the inputs are exactly job, results, app-client-id and app-private-key
#     (required) and step (optional);
#   * the token step (id app-token) takes the App from the app-client-id and
#     app-private-key inputs and requests one permission only,
#     `permission-issues: write`;
#   * a key check step (id app-keys) comes before the token step, reads the
#     app-client-id and app-private-key inputs only through its env, as
#     APP_CLIENT_ID and APP_PRIVATE_KEY, and interpolates no expression into
#     its script; run against each key empty, and both, it fails naming the
#     empty inputs and the automation environment, and with both keys set it
#     passes silently (vergil-project/vergil-actions#1432);
#   * the metadata holds no `vars.` or `secrets.` expression: a composite
#     action cannot read either, so the caller passes the secrets as inputs
#     and the variables in its step's env;
#   * the setup step (./actions/shared/setup/vergil) follows the token step
#     and has GH_TOKEN from it, so its identity check runs as the App;
#   * one step runs vrg-ops-report, after the setup step, with GH_TOKEN from
#     the token step and the job, results and step inputs in its env.
# Fixture actions check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action="${here}/../action.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'ops-report-inputs.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$action" ]; then
  printf 'ops-report-inputs.test.sh: missing %s\n' "$action" >&2
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

# shellcheck disable=SC2016 # literal GitHub Actions expressions
token_ref='${{ steps.app-token.outputs.token }}'
# shellcheck disable=SC2016 # literal GitHub Actions expressions
client_id_ref='${{ inputs.app-client-id }}'
# shellcheck disable=SC2016 # literal GitHub Actions expressions
private_key_ref='${{ inputs.app-private-key }}'

# step_index <action file> <yq select condition> — the indexes of the
# matching steps, one per line.
step_index() {
  yq -r ".runs.steps | to_entries | .[] | select($2) | .key" "$1"
}

# violations <action file> — print one line per rule the action breaks,
# nothing when it keeps them all.
violations() {
  local file="$1" inputs expected perms token keys setup report value rc
  inputs="$(yq -r '(.inputs // {}) | to_entries | .[]
    | .key + "=" + ((.value.required // false) | tostring)' "$file" | sort | paste -sd' ' -)"
  expected="app-client-id=true app-private-key=true job=true results=true step=false"
  if [ "$inputs" != "$expected" ]; then
    printf 'inputs are not %s: %s\n' "$expected" "$inputs"
  fi
  rc=0
  grep -nE '\$\{\{[^}]*(vars|secrets)\.' "$file" >"${tmp}/expr" || rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'ops-report-inputs.test.sh: grep failed (exit %s)\n' "$rc" >&2
    exit 1
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'the metadata holds a vars. or secrets. expression: %s\n' "$(paste -sd' ' "${tmp}/expr")"
  fi

  token="$(step_index "$file" '.value.id == "app-token"')"
  if [ -z "$token" ]; then
    printf 'no step has id app-token\n'
    return 0
  fi
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  if [ "$(yq -r ".runs.steps[${token}].with.\"app-id\" // \"<unset>\"" "$file")" != '${{ inputs.app-client-id }}' ]; then
    printf 'the token step app-id is not ${{ inputs.app-client-id }}\n'
  fi
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  if [ "$(yq -r ".runs.steps[${token}].with.\"private-key\" // \"<unset>\"" "$file")" != '${{ inputs.app-private-key }}' ]; then
    printf 'the token step private-key is not ${{ inputs.app-private-key }}\n'
  fi
  keys="$(step_index "$file" '.value.id == "app-keys"')"
  if [ -z "$keys" ]; then
    printf 'no step has id app-keys\n'
  else
    if [ "$keys" -ge "$token" ]; then
      printf 'the app-keys step (step %s) does not precede the token step (step %s)\n' "$keys" "$token"
    fi
    value="$(yq -r ".runs.steps[${keys}].env.APP_CLIENT_ID // \"<unset>\"" "$file")"
    if [ "$value" != "$client_id_ref" ]; then
      printf 'the app-keys step APP_CLIENT_ID is not %s: %s\n' "$client_id_ref" "$value"
    fi
    value="$(yq -r ".runs.steps[${keys}].env.APP_PRIVATE_KEY // \"<unset>\"" "$file")"
    if [ "$value" != "$private_key_ref" ]; then
      printf 'the app-keys step APP_PRIVATE_KEY is not %s: %s\n' "$private_key_ref" "$value"
    fi
    # shellcheck disable=SC2016 # the literal start of a GitHub Actions expression
    case "$(yq -r ".runs.steps[${keys}].run // \"\"" "$file")" in
      *'${{'*) printf 'the app-keys step interpolates an expression into its script\n' ;;
    esac
  fi

  perms="$(yq -r ".runs.steps[${token}].with // {} | to_entries | .[]
    | select(.key | test(\"^permission-\")) | .key + \": \" + .value" "$file" | paste -sd',' -)"
  if [ "$perms" != "permission-issues: write" ]; then
    printf 'the token permissions are not only permission-issues: write: %s\n' "${perms:-<none>}"
  fi

  setup="$(step_index "$file" '(.value.uses // "") == "./actions/shared/setup/vergil"')"
  if [ -z "$setup" ]; then
    printf 'no step uses ./actions/shared/setup/vergil\n'
  else
    if [ "$setup" -le "$token" ]; then
      printf 'the setup step (step %s) does not follow the token step\n' "$setup"
    fi
    value="$(yq -r ".runs.steps[${setup}].env.GH_TOKEN // \"<unset>\"" "$file")"
    if [ "$value" != "$token_ref" ]; then
      printf 'the setup step GH_TOKEN is not the App token: %s\n' "$value"
    fi
  fi

  report="$(step_index "$file" '(.value.run // "") | test("(^|[^a-z-])vrg-ops-report([^a-z-]|$)")')"
  if [ -z "$report" ] || [ "$(wc -l <<<"$report")" -ne 1 ]; then
    printf 'not exactly one step runs vrg-ops-report\n'
    return 0
  fi
  if [ -n "$setup" ] && [ "$report" -le "$setup" ]; then
    printf 'the report step (step %s) does not follow the setup step\n' "$report"
  fi
  value="$(yq -r ".runs.steps[${report}].env.GH_TOKEN // \"<unset>\"" "$file")"
  if [ "$value" != "$token_ref" ]; then
    printf 'the report step GH_TOKEN is not the App token: %s\n' "$value"
  fi
  for value in JOB:job RESULTS:results STEP:step; do
    # shellcheck disable=SC2016 # literal GitHub Actions expressions
    if [ "$(yq -r ".runs.steps[${report}].env.${value%%:*} // \"<unset>\"" "$file")" != "\${{ inputs.${value#*:} }}" ]; then
      printf 'the report step %s is not ${{ inputs.%s }}\n' "${value%%:*}" "${value#*:}"
    fi
  done
}

# expect_clean <case> <action file>
expect_clean() {
  local out
  out="$(violations "$2")"
  if [ -n "$out" ]; then
    fail_case "$1" "$out"
    return 0
  fi
  pass_case "$1"
}

# expect_caught <case> <action file> <substring of the expected violation>
expect_caught() {
  local out
  out="$(violations "$2")"
  case "$out" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$3', got: ${out:-<none>}" ;;
  esac
}

# Run the report step's own shell against a fake vrg-ops-report: --step is
# passed only when the input is set, and the run URL names the run attempt.
case_report_arguments() {
  local run bin argv
  run="$(yq -r '.runs.steps[] | select((.run // "") | test("vrg-ops-report")) | .run' "$action")"
  bin="${tmp}/bin"
  mkdir -p "$bin"
  argv="${tmp}/argv"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s"\n' "$argv" >"${bin}/vrg-ops-report"
  chmod +x "${bin}/vrg-ops-report"

  PATH="${bin}:${PATH}" REPO=o/r JOB=docs-refresh RESULTS=success,skipped STEP="" \
    RUN_URL=https://github.com/o/r/actions/runs/1/attempts/2 bash -c "$run"
  if [ "$(paste -sd' ' "$argv")" = "--repo o/r --job docs-refresh --results success,skipped --run-url https://github.com/o/r/actions/runs/1/attempts/2" ]; then
    pass_case "report-without-step-passes-no-step-flag"
  else
    fail_case "report-without-step-passes-no-step-flag" "argv: $(paste -sd' ' "$argv")"
  fi

  PATH="${bin}:${PATH}" REPO=o/r JOB=docs-refresh RESULTS=failure STEP="Build site" \
    RUN_URL=https://github.com/o/r/actions/runs/1/attempts/1 bash -c "$run"
  if [ "$(sed -n '9,10p' "$argv" | paste -sd'|' -)" = "--step|Build site" ]; then
    pass_case "report-with-step-passes-it-as-one-argument"
  else
    fail_case "report-with-step-passes-it-as-one-argument" "argv: $(paste -sd'|' "$argv")"
  fi

  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  if [ "$(yq -r '.runs.steps[] | select((.run // "") | test("vrg-ops-report")) | .env.RUN_URL' "$action")" \
    = '${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}/attempts/${{ github.run_attempt }}' ]; then
    pass_case "report-run-url-names-the-attempt"
  else
    fail_case "report-run-url-names-the-attempt" "RUN_URL is not the run attempt's URL"
  fi
}

# app_keys_case <case> <empty inputs, or "" for none> <APP_CLIENT_ID> <APP_PRIVATE_KEY>
# — run the key check's shell with the given keys. With no empty inputs it
# must pass and print nothing; otherwise it must fail with an ::error:: that
# names exactly those inputs and the automation environment, and offers no
# GITHUB_TOKEN.
app_keys_case() {
  local run out rc
  run="$(yq -r '.runs.steps[] | select(.id == "app-keys") | .run' "$action")"
  out="${tmp}/app-keys-out"
  rc=0
  APP_CLIENT_ID="$3" APP_PRIVATE_KEY="$4" bash -c "$run" >"$out" 2>&1 || rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" -eq 0 ] && [ ! -s "$out" ]; then
      pass_case "$1"
    else
      fail_case "$1" "exit ${rc}, output: $(cat "$out")"
    fi
    return 0
  fi
  if [ "$rc" -ne 0 ] && grep -qF "::error::" "$out" \
    && grep -qF "these inputs are empty: ${2}." "$out" \
    && grep -qF "environment: automation" "$out" \
    && ! grep -qiF "GITHUB_TOKEN" "$out"; then
    pass_case "$1"
  else
    fail_case "$1" "exit ${rc}, output: $(cat "$out")"
  fi
}

# Run the key check's own shell: both keys set, each key empty, both empty,
# and both unset.
case_app_keys() {
  local run out rc
  run="$(yq -r '.runs.steps[] | select(.id == "app-keys") | .run' "$action")"
  if [ -z "$run" ]; then
    fail_case "app-keys-step-exists" "no step has id app-keys"
    return 0
  fi

  app_keys_case "app-keys-both-set-passes-silently" "" Iv1.client-id key-pem
  app_keys_case "app-keys-empty-client-id-refused-by-name" "app-client-id" "" key-pem
  app_keys_case "app-keys-empty-private-key-refused-by-name" "app-private-key" Iv1.client-id ""
  app_keys_case "app-keys-both-empty-refused-by-name" "app-client-id app-private-key" "" ""

  out="${tmp}/app-keys-unset"
  rc=0
  env -u APP_CLIENT_ID -u APP_PRIVATE_KEY bash -c "$run" >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF "these inputs are empty: app-client-id app-private-key." "$out"; then
    pass_case "app-keys-unset-refused-by-name"
  else
    fail_case "app-keys-unset-refused-by-name" "exit ${rc}, output: $(cat "$out")"
  fi
}

# write_action <file> <token with-block> — a fixture action: the key check
# step, the token step with the given `with:` lines, the setup step and the
# report step.
write_action() {
  {
    cat <<'YAML'
inputs:
  job: {required: true}
  results: {required: true}
  step: {required: false}
  app-client-id: {required: true}
  app-private-key: {required: true}
runs:
  using: composite
  steps:
    - id: app-keys
      shell: bash
      env:
        APP_CLIENT_ID: ${{ inputs.app-client-id }}
        APP_PRIVATE_KEY: ${{ inputs.app-private-key }}
      run: test -n "$APP_CLIENT_ID" && test -n "$APP_PRIVATE_KEY"
    - id: app-token
      uses: actions/create-github-app-token@v3
      with:
YAML
    printf '%s\n' "$2"
    cat <<'YAML'
    - uses: ./actions/shared/setup/vergil
      env:
        GH_TOKEN: ${{ steps.app-token.outputs.token }}
    - shell: bash
      env:
        GH_TOKEN: ${{ steps.app-token.outputs.token }}
        JOB: ${{ inputs.job }}
        RESULTS: ${{ inputs.results }}
        STEP: ${{ inputs.step }}
      run: vrg-ops-report --job "$JOB"
YAML
  } >"$1"
}

case_fixtures() {
  local creds
  creds="        app-id: \${{ inputs.app-client-id }}
        private-key: \${{ inputs.app-private-key }}"

  write_action "${tmp}/good.yml" "${creds}
        permission-issues: write"
  expect_clean "fixture-issues-only-is-clean" "${tmp}/good.yml"

  write_action "${tmp}/extra-perm.yml" "${creds}
        permission-issues: write
        permission-contents: write"
  expect_caught "fixture-extra-permission-caught" "${tmp}/extra-perm.yml" \
    "the token permissions are not only permission-issues: write: permission-issues: write,permission-contents: write"

  write_action "${tmp}/no-perm.yml" "${creds}"
  expect_caught "fixture-unscoped-token-caught" "${tmp}/no-perm.yml" \
    "the token permissions are not only permission-issues: write: <none>"

  write_action "${tmp}/secrets.yml" "        app-id: \${{ secrets.APP_CLIENT_ID }}
        private-key: \${{ inputs.app-private-key }}
        permission-issues: write"
  expect_caught "fixture-secrets-expression-caught" "${tmp}/secrets.yml" \
    "the metadata holds a vars. or secrets. expression"

  write_action "${tmp}/vars.yml" "${creds}
        permission-issues: write"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  yq -i '.runs.steps[3].env.VRG_AUTOMATION_APP = "${{ vars.VRG_AUTOMATION_APP }}"' "${tmp}/vars.yml"
  expect_caught "fixture-vars-expression-caught" "${tmp}/vars.yml" \
    "the metadata holds a vars. or secrets. expression"

  write_action "${tmp}/extra-input.yml" "${creds}
        permission-issues: write"
  yq -i '.inputs.token = {"required": false}' "${tmp}/extra-input.yml"
  expect_caught "fixture-extra-input-caught" "${tmp}/extra-input.yml" "inputs are not"

  write_action "${tmp}/optional-key.yml" "${creds}
        permission-issues: write"
  yq -i '.inputs."app-private-key".required = false' "${tmp}/optional-key.yml"
  expect_caught "fixture-optional-key-caught" "${tmp}/optional-key.yml" "inputs are not"

  write_action "${tmp}/setup-no-token.yml" "${creds}
        permission-issues: write"
  yq -i 'del(.runs.steps[2].env)' "${tmp}/setup-no-token.yml"
  expect_caught "fixture-setup-without-token-caught" "${tmp}/setup-no-token.yml" \
    "the setup step GH_TOKEN is not the App token: <unset>"

  write_action "${tmp}/setup-first.yml" "${creds}
        permission-issues: write"
  yq -i '.runs.steps = [.runs.steps[0], .runs.steps[2], .runs.steps[1], .runs.steps[3]]' "${tmp}/setup-first.yml"
  expect_caught "fixture-setup-before-token-caught" "${tmp}/setup-first.yml" \
    "the setup step (step 1) does not follow the token step"

  write_action "${tmp}/github-token.yml" "${creds}
        permission-issues: write"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  yq -i '.runs.steps[3].env.GH_TOKEN = "${{ github.token }}"' "${tmp}/github-token.yml"
  expect_caught "fixture-report-with-github-token-caught" "${tmp}/github-token.yml" \
    "the report step GH_TOKEN is not the App token"

  write_action "${tmp}/no-report.yml" "${creds}
        permission-issues: write"
  yq -i '.runs.steps[3].run = "true"' "${tmp}/no-report.yml"
  expect_caught "fixture-no-report-step-caught" "${tmp}/no-report.yml" \
    "not exactly one step runs vrg-ops-report"

  write_action "${tmp}/no-keys.yml" "${creds}
        permission-issues: write"
  yq -i 'del(.runs.steps[0])' "${tmp}/no-keys.yml"
  expect_caught "fixture-no-key-check-caught" "${tmp}/no-keys.yml" \
    "no step has id app-keys"

  write_action "${tmp}/keys-after-token.yml" "${creds}
        permission-issues: write"
  yq -i '.runs.steps = [.runs.steps[1], .runs.steps[0], .runs.steps[2], .runs.steps[3]]' "${tmp}/keys-after-token.yml"
  expect_caught "fixture-key-check-after-token-caught" "${tmp}/keys-after-token.yml" \
    "the app-keys step (step 1) does not precede the token step (step 0)"

  write_action "${tmp}/keys-swapped.yml" "${creds}
        permission-issues: write"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  yq -i '.runs.steps[0].env.APP_PRIVATE_KEY = "${{ inputs.app-client-id }}"' "${tmp}/keys-swapped.yml"
  expect_caught "fixture-key-check-wrong-input-caught" "${tmp}/keys-swapped.yml" \
    "the app-keys step APP_PRIVATE_KEY is not"

  write_action "${tmp}/keys-interpolated.yml" "${creds}
        permission-issues: write"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  yq -i '.runs.steps[0].run = "test -n \"${{ inputs.app-client-id }}\""' "${tmp}/keys-interpolated.yml"
  expect_caught "fixture-key-check-interpolated-caught" "${tmp}/keys-interpolated.yml" \
    "the app-keys step interpolates an expression into its script"
}

expect_clean "ops-report-inputs-token-and-report-step" "$action"
case_report_arguments
case_app_keys
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
