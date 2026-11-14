#!/usr/bin/env bash
#
# Behavioural test for reports.sh — the per-language report-file contract of
# the test and audit evidence gates and the staging of one leg's reports
# (issue #1211).
#
# Framework-free and developer-runnable: `bash reports.test.sh`. CI runs it
# from .github/workflows/smoke-setup-vergil.yml. It needs only bash and
# coreutils, plus jq for the tools-JSON cases.
#
# Each stage case runs reports.sh in a scratch workspace holding chosen report
# files, then asserts the exit status, the staged file names and contents, and
# for the failure cases the `::error::` annotation naming each missing report.
# A final case checks that ci-test.yml and ci-audit.yml stage through this
# action, so a workflow cannot drift back to a fixed list of names.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reports_sh="${here}/../reports.sh"
repo_root="$(cd "${here}/../../../../.." && pwd)"

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

# Result of the last run.
rc=0
stderr=""
stdout=""
ws=""
outputs=""

# workspace <name> <file>... — a fresh workspace holding each named report,
# with its own name as content. Sets ws.
workspace() {
  local name="$1" f
  shift
  ws="${tmp}/${name}"
  mkdir -p "$ws"
  for f in "$@"; do
    printf '%s\n' "$f" >"${ws}/${f}"
  done
}

# run_reports <mode> <language> <gate> [version] [outcome] — run reports.sh in
# $ws with OUT_DIR=ci-reports.
run_reports() {
  local err out
  err="$(mktemp)"
  out="$(mktemp)"
  outputs="${ws}/github-output"
  : >"$outputs"
  rc=0
  (
    cd "$ws"
    GITHUB_OUTPUT="$outputs" MODE="$1" LANGUAGE="$2" GATE="$3" \
      VERSION="${4:-}" GATE_OUTCOME="${5:-}" OUT_DIR=ci-reports \
      bash "$reports_sh"
  ) >"$out" 2>"$err" || rc=$?
  stderr="$(cat "$err")"
  stdout="$(cat "$out")"
  rm -f "$err" "$out"
}

# staged — the sorted basenames in $ws/ci-reports, space-separated.
staged() {
  if [ -d "${ws}/ci-reports" ]; then
    (cd "${ws}/ci-reports" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
  fi
}

# assert_staged <name> <expected staged list> — exit 0 and exactly these files.
assert_staged() {
  local name="$1" expected="$2" actual
  actual="$(staged)"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    fail_case "$name" "expected staged '${expected}', got '${actual}'"
    return 1
  fi
  return 0
}

# assert_error <name> <substring>... — a non-zero exit and an ::error:: line
# holding each substring.
assert_error() {
  local name="$1" needle errors
  shift
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected a non-zero exit, got 0"
    return 1
  fi
  errors="$(grep -F -- "::error::" <<<"$stderr" || true)"
  for needle in "$@"; do
    if ! grep -qF -- "$needle" <<<"$errors"; then
      fail_case "$name" "expected an ::error:: containing '${needle}', got '${stderr}'"
      return 1
    fi
  done
  return 0
}

# --- the contract, per language and gate --------------------------------------

case_stage() {
  local name="$1" language="$2" gate="$3" expected="$4"
  shift 4
  workspace "$name" "$@"
  run_reports stage "$language" "$gate" 1.0 success
  if assert_staged "$name" "$expected"; then
    pass_case "$name"
  fi
}

case_stage python-test-stages-coverage-and-junit python test \
  "coverage-1.0.xml junit-1.0.xml " coverage.xml junit.xml
case_stage python-audit-stages-pip-audit-and-licenses python audit \
  "licenses-1.0.json pip-audit-1.0.json " pip-audit.json licenses.json
case_stage rust-test-stages-coverage-and-junit rust test \
  "coverage-1.0.xml junit-1.0.xml " coverage.xml junit.xml
case_stage rust-audit-stages-cargo-deny rust audit \
  "cargo-deny-1.0.json " cargo-deny.json

# Rust's audit report is cargo-deny.json, never Python's names: a workspace
# holding only Python's audit reports fails a passing Rust audit.
name="rust-audit-ignores-python-names"
workspace "$name" pip-audit.json licenses.json
run_reports stage rust audit 1.85 success
if assert_error "$name" "wrote no cargo-deny.json"; then
  if [ -n "$(staged)" ]; then
    fail_case "$name" "staged '$(staged)', expected nothing"
  else
    pass_case "$name"
  fi
fi

# Only declared reports are staged, so the evidence job may take every
# uploaded file.
name="undeclared-files-are-not-staged"
workspace "$name" coverage.xml junit.xml quality-ruff.json cargo-deny.json
run_reports stage rust test 1.85 success
if assert_staged "$name" "coverage-1.85.xml junit-1.85.xml "; then
  pass_case "$name"
fi

name="staged-content-is-the-report"
workspace "$name" cargo-deny.json
run_reports stage rust audit 1.85 success
if assert_staged "$name" "cargo-deny-1.85.json "; then
  if [ "$(cat "${ws}/ci-reports/cargo-deny-1.85.json")" = "cargo-deny.json" ]; then
    pass_case "$name"
  else
    fail_case "$name" "staged file does not hold the report's content"
  fi
fi

name="matrix-version-label-suffixes-the-stem"
workspace "$name" coverage.xml junit.xml
run_reports stage python test 3.14 success
if assert_staged "$name" "coverage-3.14.xml junit-3.14.xml "; then
  pass_case "$name"
fi

# --- a passing gate with a missing report fails loudly -----------------------

name="passing-gate-missing-one-report-fails-naming-it"
workspace "$name" coverage.xml
run_reports stage rust test 1.85 success
if assert_error "$name" "rust test gate passed but wrote no junit.xml"; then
  if grep -F '::error::' <<<"$stderr" | grep -F "coverage.xml" >/dev/null; then
    fail_case "$name" "named a report that exists: ${stderr}"
  else
    pass_case "$name"
  fi
fi

name="passing-gate-missing-every-report-names-each"
workspace "$name"
run_reports stage python audit 3.14 success
if assert_error "$name" "wrote no pip-audit.json" "wrote no licenses.json"; then
  pass_case "$name"
fi

name="empty-report-is-missing-and-never-staged"
workspace "$name" junit.xml
: >"${ws}/coverage.xml"
run_reports stage python test 3.14 success
if assert_error "$name" "wrote no coverage.xml"; then
  case "$(staged)" in
    *coverage*) fail_case "$name" "staged the empty coverage.xml" ;;
    *) pass_case "$name" ;;
  esac
fi

# --- a failed gate stages what exists and only notes the rest ----------------

for outcome in failure skipped cancelled; do
  name="gate-${outcome}-stages-what-exists"
  workspace "$name" coverage.xml
  run_reports stage rust test 1.85 "$outcome"
  if assert_staged "$name" "coverage-1.85.xml "; then
    if grep -qF "::notice::" <<<"$stdout" && grep -qF "junit.xml" <<<"$stdout"; then
      pass_case "$name"
    else
      fail_case "$name" "no ::notice:: naming junit.xml; stdout: ${stdout}"
    fi
  fi
done

name="missing-gate-outcome-is-not-success"
workspace "$name"
run_reports stage rust audit 1.85 ""
if assert_staged "$name" ""; then
  pass_case "$name"
fi

# --- no contract, bad input ---------------------------------------------------

for language in go cpp typescript shell ""; do
  name="no-contract-for-language-'${language}'-fails"
  workspace "nocontract-${language:-empty}" coverage.xml junit.xml
  run_reports stage "$language" test 1.0 success
  if [ -z "$language" ]; then
    needle="LANGUAGE is empty"
  else
    needle="no 'test' report contract for language '${language}'"
  fi
  if assert_error "$name" "$needle"; then
    pass_case "$name"
  fi
done

name="unknown-gate-fails"
workspace "$name" coverage.xml
run_reports stage python quality 3.14 success
if assert_error "$name" "unknown gate 'quality'"; then
  pass_case "$name"
fi

name="empty-version-fails"
workspace "$name" coverage.xml junit.xml
run_reports stage python test "" success
if assert_error "$name" "VERSION is empty"; then
  pass_case "$name"
fi

name="version-with-a-slash-fails"
workspace "$name" coverage.xml junit.xml
run_reports stage python test "../x" success
if assert_error "$name" "not a single path component"; then
  pass_case "$name"
fi

name="unknown-mode-fails"
workspace "$name"
run_reports upload python test
if assert_error "$name" "unknown MODE 'upload'"; then
  pass_case "$name"
fi

# --- tools mode ---------------------------------------------------------------

case_tools() {
  local language="$1" gate="$2" expected="$3" name actual
  name="tools-${language}-${gate}"
  workspace "$name"
  run_reports tools "$language" "$gate"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 0
  fi
  actual="$(sed -n 's/^tools=//p' "$outputs")"
  if jq -e --argjson a "$actual" --argjson e "$expected" -n '$a == $e' >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name" "expected ${expected}, got '${actual}'"
  fi
}

case_tools python test '[{"name":"pytest"},{"name":"coverage.py"}]'
case_tools python audit '[{"name":"pip-audit"},{"name":"pip-licenses"}]'
case_tools rust test '[{"name":"cargo-llvm-cov"}]'
case_tools rust audit '[{"name":"cargo-deny"}]'

name="tools-no-contract-fails"
workspace "$name"
run_reports tools go audit
if assert_error "$name" "no 'audit' report contract for language 'go'"; then
  if [ -s "$outputs" ]; then
    fail_case "$name" "wrote an output for a language with no contract"
  else
    pass_case "$name"
  fi
fi

# --- the workflows stage through this action ---------------------------------

# case_workflow <workflow> <gate> — the gate's leg stages through the action in
# stage mode with the gate step's outcome, the evidence job takes its tools
# from it, and no shell step names a report file itself.
case_workflow() {
  local wf="${repo_root}/.github/workflows/$1" gate="$2" name
  name="$1-stages-through-ci-evidence-reports"
  if [ ! -f "$wf" ]; then
    fail_case "$name" "missing ${wf}"
    return 0
  fi
  if ! grep -qE '^ +uses: \./actions/ci/evidence/reports$' "$wf"; then
    fail_case "$name" "does not use ./actions/ci/evidence/reports"
    return 0
  fi
  if ! grep -qE "^ +gate-outcome: \\$\\{\\{ steps\\.gate\\.outcome \\}\\}$" "$wf" ||
    ! grep -qE '^ +id: gate$' "$wf"; then
    fail_case "$name" "the stage step does not take the gate step's outcome"
    return 0
  fi
  if [ "$(grep -cE "^ +gate: ${gate}$" "$wf")" -lt 2 ]; then
    fail_case "$name" "the ${gate} gate is not named in both stage and tools steps"
    return 0
  fi
  if ! grep -qE '^ +tools: \$\{\{ steps\.reports\.outputs\.tools \}\}$' "$wf"; then
    fail_case "$name" "the emit step does not take its tools from the action"
    return 0
  fi
  if sed -E 's/(^|[[:space:]])#.*//' "$wf" |
    grep -qE '(pip-audit|licenses|cargo-deny|coverage|junit)[-.*]'; then
    fail_case "$name" "names a report file outside the action"
    return 0
  fi
  pass_case "$name"
}

case_workflow ci-test.yml test
case_workflow ci-audit.yml audit

printf '\nreports.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
