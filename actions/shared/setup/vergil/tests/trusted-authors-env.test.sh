#!/usr/bin/env bash
#
# Test that every step running a GitHub-touching vrg-* command receives the
# trusted-authors configuration (issue #1351, epic
# vergil-project/.github#1467, spec §5.1a).
#
# Under GitHub Actions, with no configuration file on the runner,
# vergil-tooling reads the trusted authors from $VRG_TRUSTED_AUTHORS and stops
# when it is missing or invalid. The value is the org Actions variable of the
# same name, so each step that runs such a command takes it from
# `${{ vars.VRG_TRUSTED_AUTHORS }}` in its own `env`. A composite action
# cannot read `vars`, so a step that uses a local composite action running
# such a command sets it on the `uses` step, whose env reaches the
# composite's steps.
#
# Framework-free and developer-runnable: `bash trusted-authors-env.test.sh`.
# CI runs it from .github/workflows/smoke-setup-vergil.yml and validation runs
# it with every action suite. It needs `yq` (mikefarah v4, preinstalled on
# GitHub's ubuntu runners) and touches no network.
#
# The rules, checked on every workflow in .github/workflows:
#   * no workflow-level or job-level `env` sets VRG_TRUSTED_AUTHORS;
#   * a step that sets it takes it from `${{ vars.VRG_TRUSTED_AUTHORS }}`;
#   * a step sets it when its `run` runs a GitHub-touching command, or when it
#     uses a local composite action (`./actions/...`) whose steps or shipped
#     scripts run one;
#   * cd-docs.yml's pre-deploy step sets it: it runs a caller-supplied
#     command, by default vrg-roadmap and vrg-activity-log (cd-docs-refresh).
# Comment lines are ignored when looking for a command. Fixture workflows
# check that each rule catches its violation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../../.." && pwd)"
workflows="${repo_root}/.github/workflows"

if ! command -v yq >/dev/null 2>&1; then
  printf 'trusted-authors-env.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -d "$workflows" ]; then
  printf 'trusted-authors-env.test.sh: missing %s\n' "$workflows" >&2
  exit 1
fi

# The vrg-* commands that call GitHub: each takes the whole command, bar
# vrg-ci-evidence and vrg-package, of which only the named subcommands do
# (vrg-ci-evidence assemble works offline; vrg-package matrix, build,
# check-runtime and install-test read only local files).
github_commands='vrg-(activity-log|branch-sweep|dependabot-audit|docs-stage|epic-audit|epic-rollup|github-repo-config|promote|release|roadmap|upstream-refresh)([^a-z0-9-]|$)'
github_commands+='|vrg-ci-evidence[[:space:]]+(harvest|bundle)'
github_commands+='|vrg-package[[:space:]]+(index|check-unpublished)'

# shellcheck disable=SC2016 # a literal GitHub Actions expression
expected='${{ vars.VRG_TRUSTED_AUTHORS }}'

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

# runs_github_command — exit 0 when the shell text on stdin, comment lines
# dropped, runs a GitHub-touching vrg-* command.
runs_github_command() {
  grep -vE '^[[:space:]]*#' | grep -qE "$github_commands"
}

# composite_runs_github_command <actions root> <uses path> — exit 0 when the
# local composite action at <uses path> (./actions/...) runs a GitHub-touching
# command in a `run` step or in a script it ships (its tests excluded).
composite_runs_github_command() {
  local root="$1" uses="$2" dir script
  dir="${root}/${uses#./}"
  [ -f "${dir}/action.yml" ] || return 1
  if yq -r '(.runs.steps // [])[] | (.run // "")' "${dir}/action.yml" | runs_github_command; then
    return 0
  fi
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    if runs_github_command <"$script"; then
      return 0
    fi
  done < <(find "$dir" -name '*.sh' -not -path '*/tests/*' | sort)
  return 1
}

# violations <workflow file> <actions root> — print one line per rule the
# workflow breaks, nothing when it keeps them all.
violations() {
  local wf="$1" root="$2" job idx uses has value needs
  if [ "$(yq -r '(.env // {}) | has("VRG_TRUSTED_AUTHORS")' "$wf")" = "true" ]; then
    printf 'workflow env sets VRG_TRUSTED_AUTHORS\n'
  fi
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    printf '%s: job env sets VRG_TRUSTED_AUTHORS\n' "$job"
  done < <(yq -r '(.jobs // {}) | to_entries | .[]
    | select((.value.env // {}) | has("VRG_TRUSTED_AUTHORS")) | .key' "$wf")
  # Each field defaults to <unset>, never empty: `read` with a tab IFS
  # collapses empty fields, which would shift the later ones.
  # shellcheck disable=SC2016 # $j in the yq query below is a yq variable
  while IFS=$'\t' read -r job idx uses has value; do
    if [ "$has" = "true" ] && [ "$value" != "$expected" ]; then
      printf '%s step %s: VRG_TRUSTED_AUTHORS is not %s: %s\n' "$job" "$idx" "$expected" "$value"
    fi
    needs=""
    if yq -r ".jobs.\"${job}\".steps[${idx}].run // \"\"" "$wf" | runs_github_command; then
      needs="runs a GitHub-touching vrg-* command"
    elif [[ "$uses" == ./actions/* ]] && composite_runs_github_command "$root" "$uses"; then
      needs="uses ${uses}, which runs a GitHub-touching vrg-* command"
    fi
    if [ -n "$needs" ] && [ "$has" != "true" ]; then
      printf '%s step %s %s but does not set VRG_TRUSTED_AUTHORS\n' "$job" "$idx" "$needs"
    fi
  done < <(yq -r '(.jobs // {}) | to_entries | .[] | .key as $j
    | (.value.steps // []) | to_entries | .[]
    | [$j, .key,
       (.value.uses // "<unset>"),
       ((.value.env // {}) | has("VRG_TRUSTED_AUTHORS")),
       ((.value.env // {}).VRG_TRUSTED_AUTHORS // "<unset>")] | @tsv' "$wf")
}

# expect_clean <case> <workflow file> [<actions root>]
expect_clean() {
  local out
  out="$(violations "$2" "${3:-$repo_root}")"
  if [ -n "$out" ]; then
    fail_case "$1" "$out"
    return 0
  fi
  pass_case "$1"
}

# expect_caught <case> <workflow file> <substring of the expected violation> [<actions root>]
expect_caught() {
  local out
  out="$(violations "$2" "${4:-$repo_root}")"
  case "$out" in
    *"$3"*) pass_case "$1" ;;
    *) fail_case "$1" "expected a violation containing '$3', got: ${out:-<none>}" ;;
  esac
}

case_real_workflows() {
  local wf
  for wf in "$workflows"/*.yml; do
    expect_clean "$(basename "$wf")-trusted-authors-delivered" "$wf"
  done
}

# A step that runs a caller-supplied command cannot be judged by its text.
case_pre_deploy_step() {
  local name="cd-docs-pre-deploy-step-sets-VRG_TRUSTED_AUTHORS" sel
  sel='.jobs.deploy.steps[] | select(.name == "Run pre-deploy command")'
  if [ "$(yq -r "[${sel}] | length" "${workflows}/cd-docs.yml")" != "1" ]; then
    fail_case "$name" "cd-docs.yml's deploy job has no single 'Run pre-deploy command' step"
    return 0
  fi
  if [ "$(yq -r "${sel} | (.env // {}).VRG_TRUSTED_AUTHORS // \"<unset>\"" "${workflows}/cd-docs.yml")" != "$expected" ]; then
    fail_case "$name" "the pre-deploy step does not set VRG_TRUSTED_AUTHORS from vars"
    return 0
  fi
  pass_case "$name"
}

# The command pattern: what it must and must not match.
case_command_pattern() {
  local line
  for line in \
    'vrg-epic-audit --close --window-days "$WINDOW_DAYS"' \
    'vrg-epic-rollup --task "x#1"' \
    'vrg-roadmap > docs/site/docs/roadmap.md' \
    'timeout "${T}m" vrg-ci-evidence harvest \' \
    'vrg-package check-unpublished --version "$version"' \
    'vrg-package index --config packages.toml' \
    'vrg-release'; do
    if printf '%s\n' "$line" | runs_github_command; then
      pass_case "pattern-matches: ${line}"
    else
      fail_case "pattern-matches: ${line}" "not matched"
    fi
  done
  for line in \
    'vrg-release-validate-inputs --language python' \
    'vrg-ci-evidence assemble --out-dir x' \
    'vrg-package matrix --github-output' \
    'vrg-version show' \
    '# vrg-epic-audit runs in the next step'; do
    if printf '%s\n' "$line" | runs_github_command; then
      fail_case "pattern-ignores: ${line}" "matched"
    else
      pass_case "pattern-ignores: ${line}"
    fi
  done
}

case_fixtures() {
  local root="${tmp}/repo"
  mkdir -p "${root}/actions/fake/github" "${root}/actions/fake/offline"
  cat >"${root}/actions/fake/github/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: bash "${GITHUB_ACTION_PATH}/run.sh"
YAML
  printf '#!/usr/bin/env bash\nvrg-branch-sweep --repo "$REPO" --apply\n' \
    >"${root}/actions/fake/github/run.sh"
  cat >"${root}/actions/fake/offline/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      # vrg-epic-audit is not run here.
      run: vrg-version show
YAML

  cat >"${tmp}/good.yml" <<'YAML'
jobs:
  sweep:
    steps:
      - uses: ./actions/shared/setup/vergil
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          VRG_TRUSTED_AUTHORS: ${{ vars.VRG_TRUSTED_AUTHORS }}
        run: vrg-epic-audit --close
      - uses: ./actions/fake/github
        env:
          VRG_TRUSTED_AUTHORS: ${{ vars.VRG_TRUSTED_AUTHORS }}
      - uses: ./actions/fake/offline
      - run: vrg-package matrix --github-output
YAML
  expect_clean "fixture-delivered-is-clean" "${tmp}/good.yml" "$root"

  cat >"${tmp}/missing-run.yml" <<'YAML'
jobs:
  sweep:
    steps:
      - env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: vrg-epic-audit --close
YAML
  expect_caught "fixture-run-step-without-it-caught" "${tmp}/missing-run.yml" \
    "sweep step 0 runs a GitHub-touching vrg-* command but does not set VRG_TRUSTED_AUTHORS" "$root"

  cat >"${tmp}/missing-composite.yml" <<'YAML'
jobs:
  sweep:
    steps:
      - uses: ./actions/fake/github
YAML
  expect_caught "fixture-composite-step-without-it-caught" "${tmp}/missing-composite.yml" \
    "sweep step 0 uses ./actions/fake/github, which runs a GitHub-touching vrg-* command" "$root"

  cat >"${tmp}/literal.yml" <<'YAML'
jobs:
  sweep:
    steps:
      - env:
          VRG_TRUSTED_AUTHORS: '{"human": ["someone"]}'
        run: vrg-epic-audit --close
YAML
  expect_caught "fixture-literal-value-caught" "${tmp}/literal.yml" \
    "sweep step 0: VRG_TRUSTED_AUTHORS is not" "$root"

  cat >"${tmp}/job-env.yml" <<'YAML'
jobs:
  sweep:
    env:
      VRG_TRUSTED_AUTHORS: ${{ vars.VRG_TRUSTED_AUTHORS }}
    steps:
      - run: vrg-epic-audit --close
YAML
  expect_caught "fixture-job-env-caught" "${tmp}/job-env.yml" \
    "sweep: job env sets VRG_TRUSTED_AUTHORS" "$root"

  cat >"${tmp}/workflow-env.yml" <<'YAML'
env:
  VRG_TRUSTED_AUTHORS: ${{ vars.VRG_TRUSTED_AUTHORS }}
jobs:
  sweep:
    steps:
      - run: true
YAML
  expect_caught "fixture-workflow-env-caught" "${tmp}/workflow-env.yml" \
    "workflow env sets VRG_TRUSTED_AUTHORS" "$root"
}

case_real_workflows
case_pre_deploy_step
case_command_pattern
case_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
