#!/usr/bin/env bash
#
# Test the reporting jobs of the shared unattended workflows (issue #1362,
# epic vergil-project/.github#1494, spec §5.3 and §4.1).
#
# Each shared workflow that runs an unattended job ends with a job that
# reports that job's result, under its stable name, to the org's operations
# queue through the ops-report action. A reporting job that skipped a GitHub
# job of its name, passed the wrong result, persisted the checkout's
# credentials or sat in a concurrency group (GitHub cancels an older pending
# run, which drops its report) would lose or misfile reports without any run
# failing, so this test is the guard.
#
# Framework-free and developer-runnable: `bash reporting-jobs.test.sh`. CI
# runs it from .github/workflows/smoke-ops-report.yml and validation runs it
# with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, for each reported workflow and stable name below:
#   * the workflow has one reporting job for the name: a job with exactly one
#     step using `./actions/ops/report` whose `job` input is the name, and no
#     ops-report step for any other name;
#   * the job's `if:` is `always()`, or starts with `always() && ` (cd-docs.yml
#     adds its own conditions: release-push-skip.test.sh and
#     docs-refresh-reports-once.test.sh check them);
#   * its `needs` names every GitHub job of the name, in order, and, in a
#     workflow reporting one name, every job of the workflow but itself;
#   * its `results` input is `${{ needs.<job>.result }}` of each of them,
#     comma-joined, in the same order;
#   * its first step is actions/checkout@v6 with persist-credentials: false;
#   * the ops-report step takes app-client-id and app-private-key from
#     secrets.APP_CLIENT_ID and secrets.APP_PRIVATE_KEY, and sets
#     VRG_AUTOMATION_APP and VRG_TRUSTED_AUTHORS from vars in its own env;
#   * the job has no concurrency group and `permissions: contents: read`.
# And:
#   * ops-github-config.yml reports branch-sweep only: github-config,
#     trusted-authors-check and dependabot-audit are security signals and
#     get no reporting job (spec §2.3);
#   * vergil-actions' own cd.yml passes both App secrets to its local
#     cd-docs.yml call, which runs develop's copy at once.
# Fixture copies of the workflows, each broken one way, check that each rule
# catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"

if ! command -v yq >/dev/null 2>&1; then
  printf 'reporting-jobs.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -d "$workflows" ]; then
  printf 'reporting-jobs.test.sh: missing %s\n' "$workflows" >&2
  exit 1
fi

# workflow|reporting job|stable name|the GitHub jobs of that name
reported=(
  "ops-github-config.yml|report-branch-sweep|branch-sweep|branch-sweep"
  "ops-epic-sweep.yml|report|epic-sweep|epic-sweep"
  "ops-epic-rollup.yml|report|epic-rollup|epic-rollup"
  "ops-upstream-refresh.yml|report|upstream-refresh|prepare,publish"
  "cd-docs.yml|report|docs-deploy-develop|deploy"
  "cd-docs-refresh.yml|report|docs-refresh|refresh"
  "publish-index.yml|report|publish-index|build-index,deploy"
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

# job_violations <workflow file> <job> <stable name> <needs, comma list> —
# print one line per rule the reporting job breaks.
job_violations() {
  local wf="$1" job="$2" name="$3" want_needs="$4" sel cond needs others
  local count step results want_results value n
  sel=".jobs.\"${job}\""
  if [ "$(yq -r "(.jobs // {}) | has(\"${job}\")" "$wf")" != "true" ]; then
    printf '%s: no reporting job %s\n' "$name" "$job"
    return 0
  fi
  cond="$(yq -r "${sel}.if // \"<unset>\"" "$wf")"
  if [ "$cond" != "always()" ] && [[ "$cond" != "always() && "* ]]; then
    printf '%s: the if: is not always(): %s\n' "$job" "$cond"
  fi
  needs="$(yq -r "${sel}.needs // \"\" | [.] | flatten | join(\",\")" "$wf")"
  if [ "$needs" != "$want_needs" ]; then
    printf '%s: needs is not %s: %s\n' "$job" "$want_needs" "${needs:-<unset>}"
  fi
  if [ "$(basename "$wf")" != "ops-github-config.yml" ]; then
    others="$(yq -r "(.jobs // {}) | keys | map(select(. != \"${job}\")) | sort | join(\",\")" "$wf")"
    if [ "$others" != "$(tr ',' '\n' <<<"$want_needs" | sort | paste -sd, -)" ]; then
      printf '%s: needs does not name every other job of the workflow (%s): %s\n' \
        "$job" "$others" "${needs:-<unset>}"
    fi
  fi
  count="$(yq -r "[${sel}.steps[] | select((.uses // \"\") == \"./actions/ops/report\")] | length" "$wf")"
  if [ "$count" != "1" ]; then
    printf '%s: has %s steps using ./actions/ops/report, not 1\n' "$job" "$count"
    return 0
  fi
  step="${sel}.steps[] | select((.uses // \"\") == \"./actions/ops/report\")"
  value="$(yq -r "${step} | .with.job // \"<unset>\"" "$wf")"
  if [ "$value" != "$name" ]; then
    printf '%s: the job input is not %s: %s\n' "$job" "$name" "$value"
  fi
  want_results=""
  for n in ${want_needs//,/ }; do
    want_results+="${want_results:+,}\${{ needs.${n}.result }}"
  done
  results="$(yq -r "${step} | .with.results // \"<unset>\"" "$wf")"
  if [ "$results" != "$want_results" ]; then
    printf '%s: results is not %s: %s\n' "$job" "$want_results" "$results"
  fi
  for n in app-client-id:APP_CLIENT_ID app-private-key:APP_PRIVATE_KEY; do
    value="$(yq -r "${step} | .with.\"${n%%:*}\" // \"<unset>\"" "$wf")"
    if [ "$value" != "\${{ secrets.${n#*:} }}" ]; then
      # shellcheck disable=SC2016 # a literal GitHub Actions expression
      printf '%s: %s is not ${{ secrets.%s }}: %s\n' "$job" "${n%%:*}" "${n#*:}" "$value"
    fi
  done
  for n in VRG_AUTOMATION_APP VRG_TRUSTED_AUTHORS; do
    value="$(yq -r "${step} | (.env // {}).${n} // \"<unset>\"" "$wf")"
    if [ "$value" != "\${{ vars.${n} }}" ]; then
      # shellcheck disable=SC2016 # a literal GitHub Actions expression
      printf '%s: the ops-report step %s is not ${{ vars.%s }}: %s\n' "$job" "$n" "$n" "$value"
    fi
  done
  value="$(yq -r "${sel}.steps[0].uses // \"<unset>\"" "$wf")"
  if [ "$value" != "actions/checkout@v6" ]; then
    printf '%s: the first step is not actions/checkout@v6: %s\n' "$job" "$value"
  fi
  value="$(yq -r "${sel}.steps[0].with.\"persist-credentials\" | to_string" "$wf")"
  if [ "$value" != "false" ]; then
    printf '%s: the checkout does not set persist-credentials: false: %s\n' "$job" "$value"
  fi
  if [ "$(yq -r "${sel} | has(\"concurrency\")" "$wf")" = "true" ]; then
    printf '%s: has a concurrency group\n' "$job"
  fi
  value="$(yq -o=json -I=0 "${sel}.permissions // null" "$wf")"
  if [ "$value" != '{"contents":"read"}' ]; then
    printf '%s: permissions are not exactly contents: read: %s\n' "$job" "$value"
  fi
}

# names_violations <workflow file> <stable names, comma list> — the names
# the workflow's ops-report steps report must be exactly these.
names_violations() {
  local wf="$1" want="$2" got
  got="$(yq -r '[(.jobs // {}) | .[] | (.steps // [])[]
    | select((.uses // "") == "./actions/ops/report") | .with.job // "<unset>"] | sort | join(",")' "$wf")"
  if [ "$got" != "$want" ]; then
    printf 'the ops-report steps report %s, not exactly %s\n' "${got:-<none>}" "$want"
  fi
}

# security_violations <workflow file> — ops-github-config.yml's security
# signal jobs are neither reported nor needed by a reporting job.
security_violations() {
  local wf="$1" job
  for job in github-config trusted-authors-check dependabot-audit; do
    if [ "$(yq -r "[(.jobs // {}) | .[] | (.steps // [])[]
      | select((.uses // \"\") == \"./actions/ops/report\" and .with.job == \"${job}\")] | length" "$wf")" != "0" ]; then
      printf 'the security-signal job %s is reported\n' "$job"
    fi
    if [ "$(yq -r "[(.jobs // {}) | to_entries | .[]
      | select([.value.steps // [] | .[] | select((.uses // \"\") == \"./actions/ops/report\")] | length > 0)
      | .value.needs // \"\" | [.] | flatten | .[] | select(. == \"${job}\")] | length" "$wf")" != "0" ]; then
      printf 'a reporting job needs the security-signal job %s\n' "$job"
    fi
  done
}

# cd_violations <workflow file> — cd.yml's local cd-docs.yml call passes
# both App secrets.
cd_violations() {
  local wf="$1" job value name
  job="$(yq -r '(.jobs // {}) | to_entries | .[]
    | select((.value.uses // "") == "./.github/workflows/cd-docs.yml") | .key' "$wf")"
  if [ -z "$job" ]; then
    printf 'no job calls ./.github/workflows/cd-docs.yml\n'
    return 0
  fi
  for name in APP_CLIENT_ID APP_PRIVATE_KEY; do
    value="$(yq -r ".jobs.\"${job}\".secrets | select(tag == \"!!map\") | .${name} // \"<unset>\"" "$wf")"
    # No map at all (no secrets, or secrets: inherit) prints nothing.
    value="${value:-<unset>}"
    if [ "$value" != "\${{ secrets.${name} }}" ]; then
      printf '%s: does not pass %s: %s\n' "$job" "$name" "$value"
    fi
  done
}

# all_violations <workflow dir> — every rule above, on the workflows in
# <workflow dir>.
all_violations() {
  local dir="$1" entry wf job name needs file names
  declare -A by_file=()
  for entry in "${reported[@]}"; do
    IFS='|' read -r wf job name needs <<<"$entry"
    file="${dir}/${wf}"
    if [ ! -f "$file" ]; then
      printf 'missing %s\n' "$wf"
      continue
    fi
    job_violations "$file" "$job" "$name" "$needs" | sed "s|^|${wf}: |"
    by_file[$wf]+="${by_file[$wf]:+,}${name}"
  done
  for wf in "${!by_file[@]}"; do
    names="$(tr ',' '\n' <<<"${by_file[$wf]}" | sort | paste -sd, -)"
    names_violations "${dir}/${wf}" "$names" | sed "s|^|${wf}: |"
  done
  security_violations "${dir}/ops-github-config.yml" | sed 's|^|ops-github-config.yml: |'
  cd_violations "${dir}/cd.yml" | sed 's|^|cd.yml: |'
}

# expect_caught <case> <workflow> <yq edit> <substring of the expected
# violation> — apply the edit to a copy of the workflows and expect it.
expect_caught() {
  local dir="${tmp}/$1" out
  mkdir -p "$dir"
  cp "$workflows"/*.yml "$dir"/
  if ! out="$(yq -i "$3" "${dir}/$2" 2>&1)"; then
    fail_case "$1" "the fixture edit does not apply to $2: ${out}"
    return 0
  fi
  out="$(all_violations "$dir")"
  case "$out" in
    *"$4"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$4', got: ${out:-<none>}" ;;
  esac
}

case_real_workflows() {
  local out
  out="$(all_violations "$workflows")"
  if [ -n "$out" ]; then
    fail_case "shared-workflows-report-every-unattended-job" "$out"
    return 0
  fi
  pass_case "shared-workflows-report-every-unattended-job"
}

# shellcheck disable=SC2016 # yq edits holding literal GitHub Actions expressions
case_fixtures() {
  expect_caught "fixture-no-reporting-job-caught" ops-epic-sweep.yml \
    'del(.jobs.report)' \
    "ops-epic-sweep.yml: epic-sweep: no reporting job report"
  expect_caught "fixture-if-success-caught" ops-epic-rollup.yml \
    '.jobs.report.if = "success()"' \
    "ops-epic-rollup.yml: report: the if: is not always(): success()"
  expect_caught "fixture-missing-if-caught" publish-index.yml \
    'del(.jobs.report.if)' \
    "publish-index.yml: report: the if: is not always(): <unset>"
  expect_caught "fixture-needs-one-of-two-caught" ops-upstream-refresh.yml \
    '.jobs.report.needs = "publish"' \
    "ops-upstream-refresh.yml: report: needs is not prepare,publish: publish"
  expect_caught "fixture-unreported-job-caught" publish-index.yml \
    '.jobs.extra = {"runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}' \
    "publish-index.yml: report: needs does not name every other job of the workflow (build-index,deploy,extra)"
  expect_caught "fixture-results-one-of-two-caught" publish-index.yml \
    '(.jobs.report.steps[] | select(.uses == "./actions/ops/report")).with.results = "${{ needs.deploy.result }}"' \
    "publish-index.yml: report: results is not \${{ needs.build-index.result }},\${{ needs.deploy.result }}"
  expect_caught "fixture-wrong-name-caught" cd-docs-refresh.yml \
    '(.jobs.report.steps[] | select(.uses == "./actions/ops/report")).with.job = "cd-docs-refresh"' \
    "cd-docs-refresh.yml: report: the job input is not docs-refresh: cd-docs-refresh"
  expect_caught "fixture-checkout-not-first-caught" ops-epic-sweep.yml \
    '.jobs.report.steps |= [.[1], .[0]]' \
    "ops-epic-sweep.yml: report: the first step is not actions/checkout@v6: ./actions/ops/report"
  expect_caught "fixture-persisted-credentials-caught" cd-docs.yml \
    'del(.jobs.report.steps[0].with."persist-credentials")' \
    "cd-docs.yml: report: the checkout does not set persist-credentials: false: null"
  expect_caught "fixture-concurrency-caught" ops-epic-rollup.yml \
    '.jobs.report.concurrency = {"group": "x", "cancel-in-progress": false}' \
    "ops-epic-rollup.yml: report: has a concurrency group"
  expect_caught "fixture-write-permission-caught" cd-docs.yml \
    '.jobs.report.permissions.contents = "write"' \
    "cd-docs.yml: report: permissions are not exactly contents: read"
  expect_caught "fixture-literal-client-id-caught" ops-epic-sweep.yml \
    '(.jobs.report.steps[] | select(.uses == "./actions/ops/report")).with."app-client-id" = "Iv1.0123456789abcdef"' \
    "ops-epic-sweep.yml: report: app-client-id is not \${{ secrets.APP_CLIENT_ID }}: Iv1.0123456789abcdef"
  expect_caught "fixture-no-trusted-authors-caught" ops-epic-sweep.yml \
    'del((.jobs.report.steps[] | select(.uses == "./actions/ops/report")).env.VRG_TRUSTED_AUTHORS)' \
    "ops-epic-sweep.yml: report: the ops-report step VRG_TRUSTED_AUTHORS is not \${{ vars.VRG_TRUSTED_AUTHORS }}: <unset>"
  expect_caught "fixture-security-signal-reported-caught" ops-github-config.yml \
    '.jobs.report-dependabot-audit = .jobs.report-branch-sweep
      | .jobs.report-dependabot-audit.needs = "dependabot-audit"
      | (.jobs.report-dependabot-audit.steps[] | select(.uses == "./actions/ops/report")).with.job = "dependabot-audit"' \
    "ops-github-config.yml: the security-signal job dependabot-audit is reported"
  expect_caught "fixture-security-signal-needed-caught" ops-github-config.yml \
    '.jobs.report-branch-sweep.needs = ["branch-sweep", "github-config"]' \
    "ops-github-config.yml: a reporting job needs the security-signal job github-config"
  expect_caught "fixture-two-reports-of-one-name-caught" ops-epic-sweep.yml \
    '.jobs.report2 = .jobs.report' \
    "ops-epic-sweep.yml: the ops-report steps report epic-sweep,epic-sweep, not exactly epic-sweep"
  expect_caught "fixture-cd-without-secrets-caught" cd.yml \
    'del(.jobs.docs.secrets)' \
    "cd.yml: docs: does not pass APP_CLIENT_ID: <unset>"
}

case_real_workflows
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
