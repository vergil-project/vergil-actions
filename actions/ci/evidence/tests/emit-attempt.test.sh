#!/usr/bin/env bash
#
# Test that ci/evidence/emit keeps each run attempt's evidence through a
# re-run (issue #1444). All attempts of a workflow run share one set of
# artifact names, so a re-run's upload of ci-evidence-<gate> replaced the
# earlier attempt's copy. Seen in vergil-project/vergil-fixture-ts-lib's
# CI run 45505436055: attempt 1 passed, attempt 2 (a re-run) failed, and
# the harvest of attempt 1 found only attempt 2's ci-evidence-audit.
#
# Framework-free and developer-runnable: `bash emit-attempt.test.sh`. CI
# runs it from .github/workflows/smoke-setup-vergil.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners).
#
# Cases:
#   * the emit action has exactly two upload-artifact steps, named
#     ci-evidence-<gate> (the name the released harvest matches exactly)
#     and ci-evidence-<gate>-attempt-<run_attempt>, both uploading the
#     staging directory and failing when it holds no file;
#   * every reusable workflow's emit step names a known gate;
#   * neither name, for any gate the workflows emit, matches a
#     ci-evidence-* pattern an evidence job downloads, so an evidence job
#     never merges a gate artifact, or an earlier attempt's copy, into its
#     report partials. A broken name that does match must be caught.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
action="${repo_root}/actions/ci/evidence/emit/action.yml"
workflows_dir="${repo_root}/.github/workflows"
known_gates="security test audit quality package"

if ! command -v yq >/dev/null 2>&1; then
  printf 'emit-attempt.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$action" ]; then
  printf 'emit-attempt.test.sh: missing %s\n' "$action" >&2
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

# uploads <field> — <field> of each upload-artifact step of the action.
uploads() {
  yq -r ".runs.steps[] | select((.uses // \"\") | test(\"^actions/upload-artifact@\")) | .with.\"$1\"" "$action"
}

case_two_uploads() {
  local name="emit-uploads-plain-and-per-attempt-copies" names want
  names="$(uploads name)"
  # shellcheck disable=SC2016 # the expressions are literal action text
  want='ci-evidence-${{ inputs.gate }}
ci-evidence-${{ inputs.gate }}-attempt-${{ github.run_attempt }}'
  if [ "$names" != "$want" ]; then
    fail_case "$name" "upload names are [$(tr '\n' ' ' <<<"$names")], want the plain and the per-attempt name"
    return 0
  fi
  # shellcheck disable=SC2016
  if [ "$(uploads path | sort -u)" != '${{ steps.stage.outputs.staging }}' ]; then
    fail_case "$name" "the uploads do not both take the staging directory"
    return 0
  fi
  if [ "$(uploads if-no-files-found | sort -u)" != error ]; then
    fail_case "$name" "an upload does not fail on an empty staging directory"
    return 0
  fi
  pass_case "$name"
}

# emitted_gates — the gate of every workflow emit step, one per line.
emitted_gates() {
  local wf
  for wf in "$workflows_dir"/*.yml; do
    yq -r '.jobs[].steps[]? | select(.uses == "./actions/ci/evidence/emit") | .with.gate' "$wf"
  done | sort -u
}

# download_patterns — every ci-evidence-* name or pattern a workflow
# downloads, one per line.
download_patterns() {
  local wf
  for wf in "$workflows_dir"/*.yml; do
    yq -r '.jobs[].steps[]? | select((.uses // "") | test("^actions/download-artifact@")) |
      (.with.pattern // .with.name // "") | select(test("^ci-evidence-"))' "$wf"
  done | sort -u
}

# matching <artifact> <patterns> — the patterns <artifact> matches.
matching() {
  local artifact="$1" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # Intentional glob match of the download pattern.
    # shellcheck disable=SC2053
    if [[ "$artifact" == $pattern ]]; then
      printf '%s\n' "$pattern"
    fi
  done <<<"$2"
}

gates="$(emitted_gates)"
patterns="$(download_patterns)"

case_known_gates() {
  local name="workflows-emit-known-gates" gate
  if [ -z "$gates" ]; then
    fail_case "$name" "no workflow has a ./actions/ci/evidence/emit step"
    return 0
  fi
  while IFS= read -r gate; do
    if ! grep -qw -- "$gate" <<<"$known_gates"; then
      fail_case "$name" "a workflow emits unknown gate '$gate'"
      return 0
    fi
  done <<<"$gates"
  pass_case "$name"
}

case_no_download_match() {
  local name="gate-artifacts-match-no-download-pattern" gate artifact hit
  if [ -z "$patterns" ]; then
    fail_case "$name" "no workflow downloads a ci-evidence-* artifact"
    return 0
  fi
  while IFS= read -r gate; do
    for artifact in "ci-evidence-${gate}" "ci-evidence-${gate}-attempt-1" "ci-evidence-${gate}-attempt-12"; do
      hit="$(matching "$artifact" "$patterns")"
      if [ -n "$hit" ]; then
        fail_case "$name" "$artifact matches the download pattern $hit"
        return 0
      fi
    done
  done <<<"$gates"
  pass_case "$name"
}

# The matcher must catch a name inside a download pattern, or the case above
# proves nothing.
case_matcher_catches_drift() {
  local name="matcher-catches-a-matching-name"
  if [ -z "$(matching "ci-evidence-audit-reports-attempt-1" "$patterns")" ]; then
    fail_case "$name" "ci-evidence-audit-reports-attempt-1 matched no download pattern"
    return 0
  fi
  pass_case "$name"
}

case_two_uploads
case_known_gates
case_no_download_match
case_matcher_catches_drift

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
