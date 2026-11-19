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
# exists, so the gate fails red rather than being skipped. The `build` job is
# the one exception: it is skipped by design when BUILD is off, so instead of
# a RESULTS line it is checked against its flag by ci/evidence/assert (see
# case_build below; epic vergil-project/.github#1174).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflow="${repo_root}/.github/workflows/ci-quality.yml"
assert_step="Assert all required legs succeeded"

if ! command -v yq >/dev/null 2>&1; then
  printf 'gate.test.sh needs yq on PATH\n' >&2
  exit 1
fi
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
  if ! grep -qxF "$job" <<<"$needs"; then
    fail_case "$name" "${job} is not in jobs.evidence.needs"
    return 0
  fi
  want="${job}=\${{ needs.${job}.result }}"
  if ! grep -qxF "$want" <<<"$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$results")"; then
    fail_case "$name" "no '${want}' line in the RESULTS env of '${assert_step}'"
    return 0
  fi
  pass_case "$name"
}

# The `build` job runs only when vergil-tooling turns BUILD on for the
# language (epic vergil-project/.github#1174), so a skipped build is a valid
# result and it is not gated through RESULTS. Instead it must:
#   * run only on `needs.matrix.outputs.build-enabled == 'true'`;
#   * be in jobs.evidence.needs, with `matrix` (for the flag);
#   * have no RESULTS line, which would fail every repo with BUILD off;
#   * be checked by a ci/evidence/assert step given the flag and its result,
#     placed before the emit step.
case_build() {
  local name="build-gates-quality-evidence" enabled result idx emit_idx
  if [ "$(q '.jobs.build.if')" != "needs.matrix.outputs.build-enabled == 'true'" ]; then
    fail_case "$name" "build job's if is not needs.matrix.outputs.build-enabled == 'true'"
    return 0
  fi
  if ! grep -qxF build <<<"$needs" ||
    ! grep -qxF matrix <<<"$needs"; then
    fail_case "$name" "build and matrix are not both in jobs.evidence.needs"
    return 0
  fi
  if grep -q '^[[:space:]]*build=' <<<"$results"; then
    fail_case "$name" "build has a RESULTS line in '${assert_step}'; a skipped build must not fail it"
    return 0
  fi
  idx="$(q '.jobs.evidence.steps | to_entries | .[] | select(.value.uses == "./actions/ci/evidence/assert") | .key')"
  emit_idx="$(q '.jobs.evidence.steps | to_entries | .[] | select(.value.uses == "./actions/ci/evidence/emit") | .key')"
  if [ -z "$idx" ] || [ "$(printf '%s\n' "$idx" | wc -l)" -ne 1 ]; then
    fail_case "$name" "the evidence job has not exactly one ci/evidence/assert step"
    return 0
  fi
  if [ -z "$emit_idx" ] || [ "$idx" -ge "$emit_idx" ]; then
    fail_case "$name" "the ci/evidence/assert step does not come before the emit step"
    return 0
  fi
  enabled="$(q ".jobs.evidence.steps[${idx}].with.build-enabled")"
  result="$(q ".jobs.evidence.steps[${idx}].with.build-result")"
  # shellcheck disable=SC2016 # the expressions are literal workflow text
  if [ "$enabled" != '${{ needs.matrix.outputs.build-enabled }}' ] ||
    [ "$result" != '${{ needs.build.result }}' ]; then
    fail_case "$name" "the ci/evidence/assert step is not given the matrix flag and needs.build.result"
    return 0
  fi
  pass_case "$name"
}

case_evidence_structure
while IFS= read -r job; do
  [ -n "$job" ] || continue
  if [ "$job" = build ]; then
    case_build
    continue
  fi
  case_stage "$job"
done <<<"$stage_jobs"
if ! grep -qxF build <<<"$stage_jobs"; then
  fail_case "build-gates-quality-evidence" "ci-quality.yml has no build job"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
