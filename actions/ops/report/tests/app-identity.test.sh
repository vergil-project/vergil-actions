#!/usr/bin/env bash
#
# Test that the shared unattended jobs write as the org automation App
# (issue #1363, epic vergil-project/.github#1494, spec §5.4).
#
# Every unattended job's write steps use the App token; a step keeps
# GITHUB_TOKEN only as a recorded exception, with its reason. A write step
# that slid back to GITHUB_TOKEN, a deploy commit made as
# github-actions[bot], or an App job that wrote before checking its token
# against VRG_AUTOMATION_APP would still turn every run green, so this test
# is the guard.
#
# Framework-free and developer-runnable: `bash app-identity.test.sh`. CI
# runs it from .github/workflows/smoke-ops-report.yml and validation runs it
# with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, on publish-index.yml, cd-docs.yml, cd-docs-refresh.yml,
# ops-github-config.yml, ops-epic-sweep.yml and ops-epic-rollup.yml:
#   * no `permissions:` block, at workflow or job level, grants GITHUB_TOKEN
#     a write scope, except the recorded exception below;
#   * no step reads GITHUB_TOKEN (`secrets.GITHUB_TOKEN` or `github.token`)
#     except the read-only steps listed below;
#   * cd-docs.yml's deploy job, the one job of the six that pushes with git,
#     declares the automation environment, mints a Contents-write App token
#     as its first step and checks out with that token;
#   * cd-docs.yml's deploy step passes the App's bot identity, from the
#     git-identity step, to actions/cd/docs/deploy;
#   * actions/cd/docs/deploy sets the git identity only from its required
#     git-user-name and git-user-email inputs, refuses empty ones, and names
#     no github-actions[bot];
#   * branch-sweep, dependabot-audit, epic-sweep and epic-rollup each run
#     `vrg-whoami --mode` with the App token and VRG_AUTOMATION_APP after
#     the token step and before any other step holds the token, and fail
#     unless it prints automation.
# Fixture copies of the files, each broken one way, check that each rule
# catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"
deploy_action="${repo_root}/actions/cd/docs/deploy/action.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'app-identity.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -d "$workflows" ] || [ ! -f "$deploy_action" ]; then
  printf 'app-identity.test.sh: missing %s or %s\n' "$workflows" "$deploy_action" >&2
  exit 1
fi

files=(
  publish-index.yml
  cd-docs.yml
  cd-docs-refresh.yml
  ops-github-config.yml
  ops-epic-sweep.yml
  ops-epic-rollup.yml
)

# The recorded identity exception (spec §5.4, recorded in §4.1 by Task 19b):
# workflow|job|the job's permissions, as compact JSON. publish-index's deploy
# job runs in the github-pages environment its Pages deployment is made to,
# and a job declares one environment, so it cannot read the App keys, which
# live only in the automation environment (epic vergil-project/.github#1384).
write_exceptions=(
  'publish-index.yml|deploy|{"pages":"write","id-token":"write"}'
)

# The steps that read GITHUB_TOKEN, each read-only: workflow|job|step name.
github_token_reads=(
  # Release downloads and `gh attestation verify`; the job runs in the
  # index-signing environment, so it cannot read the App keys.
  'publish-index.yml|build-index|Build, verify and sign the index'
  # The caller's page generation reads the public org .github epics.
  'cd-docs.yml|deploy|Run pre-deploy command'
)

# workflow|job of each App job that checks its token before its first write.
verified_jobs=(
  'ops-github-config.yml|branch-sweep'
  'ops-github-config.yml|dependabot-audit'
  'ops-epic-sweep.yml|epic-sweep'
  'ops-epic-rollup.yml|epic-rollup'
)

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

# in_list <word> <list...> — whether <word> is one of <list>.
in_list() {
  local w="$1" x
  shift
  for x in "$@"; do
    [ "$x" = "$w" ] && return 0
  done
  return 1
}

# permission_violations <workflow file> — no permissions block grants a
# write scope, bar a recorded exception with exactly its permissions.
permission_violations() {
  local wf="$1" name job perms
  name="$(basename "$wf")"
  perms="$(yq -o=json -I=0 '.permissions // {}' "$wf")"
  if [ "$(yq -r '[(.permissions // {}) | .[] | select(. == "write")] | length' "$wf")" != "0" ]; then
    printf 'the workflow permissions grant a write scope: %s\n' "$perms"
  fi
  while IFS=$'\t' read -r job perms; do
    [ -n "$job" ] || continue
    if in_list "${name}|${job}|${perms}" "${write_exceptions[@]}"; then
      continue
    fi
    printf '%s: the job permissions grant a write scope: %s\n' "$job" "$perms"
  done < <(yq -r '(.jobs // {}) | to_entries | .[]
    | select([(.value.permissions // {}) | .[] | select(. == "write")] | length > 0)
    | .key + "\t" + (.value.permissions | to_json(0))' "$wf")
}

# token_read_violations <workflow file> — every step that reads GITHUB_TOKEN
# is a listed read-only step.
token_read_violations() {
  local wf="$1" name job step
  name="$(basename "$wf")"
  # shellcheck disable=SC2016 # $j in the yq query below is a yq variable
  while IFS=$'\t' read -r job step; do
    [ -n "$job" ] || continue
    if in_list "${name}|${job}|${step}" "${github_token_reads[@]}"; then
      continue
    fi
    printf '%s step %s: reads GITHUB_TOKEN\n' "$job" "$step"
  done < <(yq -r '(.jobs // {}) | to_entries | .[] | .key as $j
    | (.value.steps // []) | to_entries | .[]
    | select((.value | to_yaml) | test("(?i)(secrets\.github_token|github\.token)"))
    | [$j, (.value.name // ("#" + (.key | tostring)))] | @tsv' "$wf")
}

# deploy_violations <cd-docs.yml> — the docs deploy pushes as the App.
deploy_violations() {
  local wf="$1" sel value
  sel='.jobs.deploy'
  value="$(yq -r "${sel}.environment // \"<unset>\"" "$wf")"
  if [ "$value" != "automation" ]; then
    printf 'deploy: the environment is not automation: %s\n' "$value"
  fi
  value="$(yq -r "${sel}.steps[0].id // \"<unset>\"" "$wf")|$(yq -r "${sel}.steps[0].uses // \"<unset>\"" "$wf")"
  if [ "$value" != "app-token|actions/create-github-app-token@v3" ]; then
    printf 'deploy: the first step is not the app-token step: %s\n' "$value"
  fi
  value="$(yq -r "${sel}.steps[0].with | to_entries | map(select(.key | test(\"^permission-\")) | .key + \": \" + .value) | join(\",\")" "$wf")"
  if [ "$value" != "permission-contents: write" ]; then
    printf 'deploy: the App token permissions are not only permission-contents: write: %s\n' "${value:-<none>}"
  fi
  value="$(yq -r "[${sel}.steps[0].with | has(\"owner\"), has(\"repositories\")] | any" "$wf")"
  if [ "$value" != "false" ]; then
    printf 'deploy: the App token is not scoped to the calling repo\n'
  fi
  value="$(yq -r "[${sel}.steps[] | select((.uses // \"\") == \"actions/checkout@v6\")] | length" "$wf")"
  if [ "$value" != "1" ]; then
    printf 'deploy: has %s checkout steps, not 1\n' "$value"
  else
    value="$(yq -r "${sel}.steps[] | select((.uses // \"\") == \"actions/checkout@v6\") | .with.token // \"<unset>\"" "$wf")"
    # shellcheck disable=SC2016 # a literal GitHub Actions expression
    if [ "$value" != '${{ steps.app-token.outputs.token }}' ]; then
      printf 'deploy: the checkout does not use the App token: %s\n' "$value"
    fi
  fi
  value="$(yq -r "[${sel}.steps[] | select((.uses // \"\") == \"./actions/cd/docs/deploy\")] | length" "$wf")"
  if [ "$value" != "1" ]; then
    printf 'deploy: has %s deploy steps, not 1\n' "$value"
    return 0
  fi
  for value in git-user-name:name git-user-email:email; do
    local got
    got="$(yq -r "${sel}.steps[] | select((.uses // \"\") == \"./actions/cd/docs/deploy\") | .with.\"${value%%:*}\" // \"<unset>\"" "$wf")"
    if [ "$got" != "\${{ steps.git-identity.outputs.${value#*:} }}" ]; then
      # shellcheck disable=SC2016 # a literal GitHub Actions expression
      printf 'deploy: %s is not ${{ steps.git-identity.outputs.%s }}: %s\n' \
        "${value%%:*}" "${value#*:}" "$got"
    fi
  done
  value="$(yq -r "${sel}.steps[] | select(.id == \"git-identity\") | .env.GH_TOKEN // \"<unset>\"" "$wf")"
  # shellcheck disable=SC2016 # a literal GitHub Actions expression
  if [ "$value" != '${{ steps.app-token.outputs.token }}' ]; then
    printf 'deploy: the git-identity step does not look up the App with its token: %s\n' "${value:-<unset>}"
  fi
}

# action_violations <action.yml> — the deploy action's git identity comes
# only from its inputs.
action_violations() {
  local action="$1" n run
  if grep -q 'github-actions\[bot\]' "$action"; then
    printf 'names github-actions[bot]\n'
  fi
  for n in git-user-name git-user-email; do
    if [ "$(yq -r ".inputs.\"${n}\".required // false" "$action")" != "true" ]; then
      printf 'the %s input is not required\n' "$n"
    fi
    if [ "$(yq -r ".inputs.\"${n}\" | has(\"default\")" "$action")" != "false" ]; then
      printf 'the %s input has a default\n' "$n"
    fi
  done
  run="$(yq -r '.runs.steps[] | select(.name == "Configure git identity") | .run // ""' "$action")"
  # shellcheck disable=SC2016 # literal shell text the step must contain
  for n in 'git config --global user.name "$GIT_USER_NAME"' \
    'git config --global user.email "$GIT_USER_EMAIL"' \
    '[ -z "$GIT_USER_NAME" ]' '[ -z "$GIT_USER_EMAIL" ]'; do
    case "$run" in
      *"$n"*) ;;
      *) printf 'the Configure git identity step does not run: %s\n' "$n" ;;
    esac
  done
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  if [ "$(yq -r '.runs.steps[] | select(.name == "Configure git identity") | .env.GIT_USER_NAME // ""' "$action")" != '${{ inputs.git-user-name }}' ] ||
    [ "$(yq -r '.runs.steps[] | select(.name == "Configure git identity") | .env.GIT_USER_EMAIL // ""' "$action")" != '${{ inputs.git-user-email }}' ]; then
    printf 'the Configure git identity step does not take GIT_USER_NAME and GIT_USER_EMAIL from the inputs\n'
  fi
}

# verify_violations <workflow file> <job> — the job checks its App token
# against VRG_AUTOMATION_APP before any other step holds the token.
verify_violations() {
  local wf="$1" job="$2" sel token_idx verify_idx first_use run
  sel=".jobs.\"${job}\""
  token_idx="$(yq -r "${sel}.steps | to_entries | .[] | select(.value.id == \"app-token\") | .key" "$wf")"
  if [ -z "$token_idx" ]; then
    printf '%s: has no app-token step\n' "$job"
    return 0
  fi
  verify_idx="$(yq -r "[${sel}.steps | to_entries | .[] | select((.value.run // \"\") | test(\"vrg-whoami --mode\")) | .key] | .[0] // \"\"" "$wf")"
  if [ -z "$verify_idx" ]; then
    printf '%s: no step runs vrg-whoami --mode\n' "$job"
    return 0
  fi
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  if [ "$(yq -r "${sel}.steps[${verify_idx}].env.GH_TOKEN // \"\"" "$wf")" != '${{ steps.app-token.outputs.token }}' ] ||
    [ "$(yq -r "${sel}.steps[${verify_idx}].env.VRG_AUTOMATION_APP // \"\"" "$wf")" != '${{ vars.VRG_AUTOMATION_APP }}' ]; then
    printf '%s: the vrg-whoami step does not hold the App token and VRG_AUTOMATION_APP\n' "$job"
  fi
  if [ "$verify_idx" -le "$token_idx" ]; then
    printf '%s: the vrg-whoami step runs before the app-token step\n' "$job"
  fi
  first_use="$(yq -r "[${sel}.steps | to_entries | .[]
    | select(.key != ${verify_idx})
    | select((.value | to_yaml) | test(\"steps\\\\.app-token\\\\.outputs\\\\.token\"))
    | .key] | .[0] // \"\"" "$wf")"
  if [ -z "$first_use" ]; then
    printf '%s: no step uses the App token\n' "$job"
  elif [ "$first_use" -lt "$verify_idx" ]; then
    printf '%s: step %s holds the App token before the vrg-whoami check\n' "$job" "$first_use"
  fi
  run="$(yq -r "${sel}.steps[${verify_idx}].run" "$wf")"
  # shellcheck disable=SC2016 # literal shell text the step must contain
  case "$run" in
    *'"$(vrg-whoami --mode)"'*'!= "automation"'*) ;;
    *) printf '%s: the vrg-whoami step does not fail unless the mode is automation\n' "$job" ;;
  esac
}

# all_violations <workflow dir> <action file> — every rule above.
all_violations() {
  local dir="$1" action="$2" f entry wf job
  for f in "${files[@]}"; do
    if [ ! -f "${dir}/${f}" ]; then
      printf 'missing %s\n' "$f"
      continue
    fi
    permission_violations "${dir}/${f}" | sed "s|^|${f}: |"
    token_read_violations "${dir}/${f}" | sed "s|^|${f}: |"
  done
  deploy_violations "${dir}/cd-docs.yml" | sed 's|^|cd-docs.yml: |'
  action_violations "$action" | sed 's|^|cd/docs/deploy: |'
  for entry in "${verified_jobs[@]}"; do
    IFS='|' read -r wf job <<<"$entry"
    verify_violations "${dir}/${wf}" "$job" | sed "s|^|${wf}: |"
  done
}

# expect_caught <case> <file: a workflow name or "action"> <yq edit>
# <substring of the expected violation> — apply the edit to a copy of the
# files and expect it.
expect_caught() {
  local dir="${tmp}/$1" out target
  mkdir -p "$dir"
  cp "$workflows"/*.yml "$dir"/
  cp "$deploy_action" "${dir}/action.yml.fixture"
  if [ "$2" = "action" ]; then
    target="${dir}/action.yml.fixture"
  else
    target="${dir}/$2"
  fi
  if ! out="$(yq -i "$3" "$target" 2>&1)"; then
    fail_case "$1" "the fixture edit does not apply to $2: ${out}"
    return 0
  fi
  out="$(all_violations "$dir" "${dir}/action.yml.fixture")"
  case "$out" in
    *"$4"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$4', got: ${out:-<none>}" ;;
  esac
}

case_real_files() {
  local out
  out="$(all_violations "$workflows" "$deploy_action")"
  if [ -n "$out" ]; then
    fail_case "shared-jobs-write-as-the-app" "$out"
    return 0
  fi
  pass_case "shared-jobs-write-as-the-app"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  expect_caught "fixture-workflow-write-permission-caught" cd-docs.yml \
    '.permissions.contents = "write"' \
    'cd-docs.yml: the workflow permissions grant a write scope: {"contents":"write"}'
  expect_caught "fixture-job-write-permission-caught" cd-docs-refresh.yml \
    '.jobs.refresh.permissions.contents = "write"' \
    'cd-docs-refresh.yml: refresh: the job permissions grant a write scope: {"contents":"write"}'
  expect_caught "fixture-exception-widened-caught" publish-index.yml \
    '.jobs.deploy.permissions.contents = "write"' \
    'publish-index.yml: deploy: the job permissions grant a write scope'
  expect_caught "fixture-unlisted-github-token-caught" ops-epic-sweep.yml \
    '(.jobs.epic-sweep.steps[] | select(.name == "Reconcile epic/task drift, drain archives, attach orphans")).env.GH_TOKEN = "${{ github.token }}"' \
    'ops-epic-sweep.yml: epic-sweep step Reconcile epic/task drift, drain archives, attach orphans: reads GITHUB_TOKEN'
  expect_caught "fixture-secrets-github-token-caught" cd-docs.yml \
    '(.jobs.deploy.steps[] | select(.name == "Deploy docs")).env.GH_TOKEN = "${{ secrets.GITHUB_TOKEN }}"' \
    'cd-docs.yml: deploy step Deploy docs: reads GITHUB_TOKEN'
  expect_caught "fixture-deploy-no-environment-caught" cd-docs.yml \
    'del(.jobs.deploy.environment)' \
    'cd-docs.yml: deploy: the environment is not automation: <unset>'
  expect_caught "fixture-deploy-token-not-first-caught" cd-docs.yml \
    '.jobs.deploy.steps |= [.[1], .[0]] + .[2:]' \
    'cd-docs.yml: deploy: the first step is not the app-token step'
  expect_caught "fixture-deploy-token-widened-caught" cd-docs.yml \
    '.jobs.deploy.steps[0].with."permission-workflows" = "write"' \
    'cd-docs.yml: deploy: the App token permissions are not only permission-contents: write'
  expect_caught "fixture-deploy-token-org-wide-caught" cd-docs.yml \
    '.jobs.deploy.steps[0].with.owner = "${{ github.repository_owner }}"' \
    'cd-docs.yml: deploy: the App token is not scoped to the calling repo'
  expect_caught "fixture-checkout-default-token-caught" cd-docs.yml \
    'del((.jobs.deploy.steps[] | select(.uses == "actions/checkout@v6")).with.token)' \
    'cd-docs.yml: deploy: the checkout does not use the App token: <unset>'
  expect_caught "fixture-deploy-identity-missing-caught" cd-docs.yml \
    'del((.jobs.deploy.steps[] | select(.uses == "./actions/cd/docs/deploy")).with."git-user-email")' \
    'cd-docs.yml: deploy: git-user-email is not ${{ steps.git-identity.outputs.email }}: <unset>'
  expect_caught "fixture-identity-lookup-default-token-caught" cd-docs.yml \
    '(.jobs.deploy.steps[] | select(.id == "git-identity")).env.GH_TOKEN = "${{ github.token }}"' \
    'cd-docs.yml: deploy: the git-identity step does not look up the App with its token'
  expect_caught "fixture-action-actions-bot-caught" action \
    '(.runs.steps[] | select(.name == "Configure git identity")).run = "git config --global user.name \"github-actions[bot]\"\n"' \
    'cd/docs/deploy: names github-actions[bot]'
  expect_caught "fixture-action-identity-default-caught" action \
    '.inputs."git-user-name".default = "someone"' \
    'cd/docs/deploy: the git-user-name input has a default'
  expect_caught "fixture-action-identity-optional-caught" action \
    '.inputs."git-user-email".required = false' \
    'cd/docs/deploy: the git-user-email input is not required'
  expect_caught "fixture-action-empty-unchecked-caught" action \
    '(.runs.steps[] | select(.name == "Configure git identity")).run |= sub("\[ -z \"\$GIT_USER_EMAIL\" \]"; "false")' \
    'cd/docs/deploy: the Configure git identity step does not run: [ -z "$GIT_USER_EMAIL" ]'
  expect_caught "fixture-verify-missing-caught" ops-epic-rollup.yml \
    'del(.jobs.epic-rollup.steps[] | select((.run // "") | test("vrg-whoami")))' \
    'ops-epic-rollup.yml: epic-rollup: no step runs vrg-whoami --mode'
  expect_caught "fixture-verify-after-write-caught" ops-github-config.yml \
    '.jobs.branch-sweep.steps |= (. as $s | [$s[0], $s[1], $s[2], $s[4], $s[3]])' \
    'ops-github-config.yml: branch-sweep: step 3 holds the App token before the vrg-whoami check'
  expect_caught "fixture-verify-without-variable-caught" ops-github-config.yml \
    'del((.jobs.dependabot-audit.steps[] | select((.run // "") | test("vrg-whoami"))).env.VRG_AUTOMATION_APP)' \
    'ops-github-config.yml: dependabot-audit: the vrg-whoami step does not hold the App token and VRG_AUTOMATION_APP'
  expect_caught "fixture-verify-mode-unchecked-caught" ops-epic-sweep.yml \
    '(.jobs.epic-sweep.steps[] | select((.run // "") | test("vrg-whoami"))).run = "vrg-whoami --mode\n"' \
    'ops-epic-sweep.yml: epic-sweep: the vrg-whoami step does not fail unless the mode is automation'
}

case_real_files
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
