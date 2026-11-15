#!/usr/bin/env bash
#
# Test that the security gate's evidence.json names the scanners whose SARIF
# it holds (issue #1215). Before this, ci-security's evidence job passed no
# `tools` to the emit action, so the gate's manifest entry said
# `"tools": []` beside three SARIF reports.
#
# Framework-free and developer-runnable: `bash security-tools.test.sh`. CI
# runs it from .github/workflows/smoke-setup-vergil.yml. It needs `yq`
# (mikefarah v4) and `jq`, both preinstalled on GitHub's ubuntu runners.
#
# In ci-security.yml, a scanner is a job with a step that uploads a
# `ci-evidence-security-part-<scanner>` artifact. The checks:
#   * the evidence job's `if` requires every scanner but codeql to have
#     succeeded, so naming those scanners unconditionally is true;
#   * the "Emit ci-evidence-security artifact" step's `tools` is
#     `needs.codeql.result == 'success' && '<A>' || '<B>'`, where <A> names
#     every scanner and <B> every scanner but codeql (a skipped codeql job
#     writes no SARIF, so it is not named), each a JSON array of
#     {"name": "<scanner>"} objects.
# The same checks then run against two broken copies of the workflow (a
# scanner missing from the tools, and a scanner partial the tools do not
# name), which must fail, so the test is shown to catch the drift it guards.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflow="${repo_root}/.github/workflows/ci-security.yml"
emit_step="Emit ci-evidence-security artifact"

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'security-tools.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done
if [ ! -f "$workflow" ]; then
  printf 'security-tools.test.sh: missing %s\n' "$workflow" >&2
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

# scanners <workflow> — the scanner names, sorted, one per line.
scanners() {
  yq -r '.jobs[].steps[]? | select(.uses == "actions/upload-artifact*") |
    .with.name | select(. == "ci-evidence-security-part-*")' "$1" |
    sed 's/^ci-evidence-security-part-//' | sort -u
}

# names_of <json-array> — the array's "name" values, sorted, one per line.
# Fails when the text is not a JSON array of objects with a string name.
names_of() {
  jq -r 'if type == "array" and all(.[]; type == "object" and
      (.name | type) == "string") then .[].name else error("bad tools") end' \
    <<<"$1" | sort
}

# check_workflow <workflow> — prints the first problem found and fails, or
# succeeds silently.
check_workflow() {
  local wf="$1" all want_a want_b tools arrays a b evidence_if s
  all="$(scanners "$wf")"
  if [ -z "$all" ]; then
    echo "no job uploads a ci-evidence-security-part-* artifact"
    return 1
  fi
  if ! printf '%s\n' "$all" | grep -qxF codeql; then
    echo "no codeql scanner partial"
    return 1
  fi

  evidence_if="$(yq -r '.jobs.evidence.if' "$wf")"
  while IFS= read -r s; do
    [ "$s" = codeql ] && continue
    if ! grep -qF "needs.${s}.result == 'success'" <<<"$evidence_if"; then
      echo "the evidence job's if does not require ${s} to succeed"
      return 1
    fi
  done <<<"$all"

  tools="$(yq -r ".jobs.evidence.steps[] | select(.name == \"${emit_step}\") |
    .with.tools" "$wf")"
  if [ -z "$tools" ] || [ "$tools" = null ]; then
    echo "the '${emit_step}' step passes no tools"
    return 1
  fi
  if ! grep -qF "needs.codeql.result == 'success' &&" <<<"$tools"; then
    echo "the tools are not chosen on needs.codeql.result == 'success'"
    return 1
  fi
  arrays="$(grep -oE "'\[[^']*\]'" <<<"$tools" | sed "s/^'//;s/'\$//")"
  if [ "$(wc -l <<<"$arrays")" -ne 2 ]; then
    echo "the tools expression does not hold exactly two JSON arrays"
    return 1
  fi
  if ! a="$(names_of "$(sed -n 1p <<<"$arrays")" 2>/dev/null)" ||
    ! b="$(names_of "$(sed -n 2p <<<"$arrays")" 2>/dev/null)"; then
    echo "a tools array is not a JSON array of {\"name\": ...} objects"
    return 1
  fi
  want_a="$all"
  want_b="$(grep -vxF codeql <<<"$all")"
  if [ "$a" != "$want_a" ]; then
    echo "with codeql passed, the tools name [$(tr '\n' ' ' <<<"$a")]," \
      "not every scanner [$(tr '\n' ' ' <<<"$want_a")]"
    return 1
  fi
  if [ "$b" != "$want_b" ]; then
    echo "with codeql skipped, the tools name [$(tr '\n' ' ' <<<"$b")]," \
      "not [$(tr '\n' ' ' <<<"$want_b")]"
    return 1
  fi
}

# The real workflow must pass.
if msg="$(check_workflow "$workflow")"; then
  pass_case "ci-security-names-its-scanners"
else
  fail_case "ci-security-names-its-scanners" "$msg"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect_broken <name> <workflow-copy> — the copy must fail the checks.
expect_broken() {
  if msg="$(check_workflow "$2")"; then
    fail_case "$1" "a broken workflow passed the checks"
  else
    pass_case "$1 (${msg})"
  fi
}

# A scanner dropped from the tools, leaving both arrays valid JSON.
yq ".jobs.evidence.steps[] |= (select(.name == \"${emit_step}\") .with.tools |=
  sub(\",\\{\\\"name\\\":\\\"semgrep\\\"\\}\"; \"\"))" "$workflow" \
  >"${tmp}/dropped.yml"
expect_broken "detects-a-scanner-missing-from-the-tools" "${tmp}/dropped.yml"

# A new scanner partial the tools do not name, required by the evidence job.
yq '.jobs.extra = {"runs-on": "ubuntu-24.04", "steps": [{"uses":
  "actions/upload-artifact@v7", "with": {"name":
  "ci-evidence-security-part-extra", "path": "extra.sarif"}}]} |
  .jobs.evidence.if += " && needs.extra.result == '"'"'success'"'"'"' \
  "$workflow" >"${tmp}/extra.yml"
expect_broken "detects-a-scanner-partial-the-tools-omit" "${tmp}/extra.yml"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
