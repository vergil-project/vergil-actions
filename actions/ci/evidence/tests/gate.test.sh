#!/usr/bin/env bash
#
# Test that every ci-quality stage job is wired into the `quality / evidence`
# gate, so a failed or skipped stage fails the required gate instead of
# leaving it green by absence (Review Focus 5 of epic
# vergil-project/.github#488).
#
# Framework-free and developer-runnable: `bash gate.test.sh`. CI runs it from
# .github/workflows/smoke-setup-vergil.yml. It needs `yq` (mikefarah v4,
# preinstalled on GitHub's ubuntu runners).
#
# For ci-quality.yml, every job except `matrix`, `setup` and `evidence` is a
# stage job. Each stage job must:
#   * be listed in `jobs.evidence.needs`, and
#   * have a line `<job>=${{ needs.<job>.result }}` in the RESULTS env of the
#     evidence step named "Assert all required legs succeeded".
# It also checks the evidence job runs `if: always()` and that the assert step
# exists, so the gate fails red rather than being skipped.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflow="${repo_root}/.github/workflows/ci-quality.yml"
assert_step="Assert all required legs succeeded"

for tool in yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'gate.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done
if [ ! -f "$workflow" ]; then
  printf 'gate.test.sh: missing %s\n' "$workflow" >&2
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

# q <yq expression>
q() {
  yq -r "$1" "$workflow"
}

stage_jobs="$(q '.jobs | keys | .[] | select(. != "matrix" and . != "setup" and . != "evidence")')"
needs="$(q '.jobs.evidence.needs | [.] | flatten | .[]')"
results="$(q ".jobs.evidence.steps[] | select(.name == \"${assert_step}\") | .env.RESULTS")"

case_evidence_structure() {
  local name="evidence-job-fails-red-not-skipped"
  if [ -z "$stage_jobs" ]; then
    fail_case "$name" "ci-quality.yml has no stage jobs"
    return 0
  fi
  if [ "$(q '.jobs.evidence.if')" != "always()" ]; then
    fail_case "$name" "evidence job is not 'if: always()'"
    return 0
  fi
  if [ -z "$results" ] || [ "$results" = "null" ]; then
    fail_case "$name" "no '${assert_step}' step with a RESULTS env"
    return 0
  fi
  pass_case "$name"
}

# case_stage <job>
case_stage() {
  local job="$1" name="${1}-gates-quality-evidence" want
  if ! printf '%s\n' "$needs" | grep -qxF "$job"; then
    fail_case "$name" "${job} is not in jobs.evidence.needs"
    return 0
  fi
  want="${job}=\${{ needs.${job}.result }}"
  if ! printf '%s\n' "$results" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
    grep -qxF "$want"; then
    fail_case "$name" "no '${want}' line in the RESULTS env of '${assert_step}'"
    return 0
  fi
  pass_case "$name"
}

case_evidence_structure
while IFS= read -r job; do
  [ -n "$job" ] || continue
  case_stage "$job"
done <<<"$stage_jobs"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
