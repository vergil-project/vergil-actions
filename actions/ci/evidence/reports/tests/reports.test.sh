#!/usr/bin/env bash
#
# Behavioural test for reports.sh — the per-language report-file contract of
# the test and audit evidence gates and of the quality gate's lint and
# typecheck legs, the staging of one leg's reports, and expect mode's check of
# the quality evidence job's reports (issues #1211, #1249, #1260).
#
# Framework-free and developer-runnable: `bash reports.test.sh`. CI runs it
# from .github/workflows/smoke-setup-vergil.yml. It needs only bash and
# coreutils, plus jq for the tools-JSON cases.
#
# Each stage case runs reports.sh in a scratch workspace holding chosen report
# files, then asserts the exit status, the staged file names and contents, and
# for the failure cases the `::error::` annotation naming each missing report.
# A fleet language with no contract (go, cpp) must warn, stage nothing and
# list no tools, while every bad input still fails. TypeScript has a contract
# for every gate (epic vergil-project/.github#1174) and warns on none. A repository
# with no fleet primary language (shell, a Claude plugin, none) gets a notice
# on its lint and typecheck legs instead. The final cases check that
# ci-test.yml, ci-audit.yml and ci-quality.yml stage through this action, so a
# workflow cannot drift back to a fixed list of names.
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
case_stage typescript-test-stages-coverage-and-junit typescript test \
  "coverage-1.0.xml junit-1.0.xml " coverage.xml junit.xml npm-audit.json
case_stage typescript-audit-stages-npm-audit typescript audit \
  "npm-audit-1.0.json " npm-audit.json coverage.xml junit.xml

# TypeScript's audit report is npm-audit.json, never another language's
# names: a workspace holding only Python's and Rust's audit reports fails a
# passing TypeScript audit.
name="typescript-audit-ignores-other-names"
workspace "$name" pip-audit.json licenses.json cargo-deny.json
run_reports stage typescript audit node-24 success
if assert_error "$name" "typescript audit gate passed but wrote no npm-audit.json"; then
  if [ -n "$(staged)" ]; then
    fail_case "$name" "staged '$(staged)', expected nothing"
  else
    pass_case "$name"
  fi
fi

# A passing TypeScript test leg that wrote no junit.xml fails naming it, and
# still stages the coverage.xml it has.
name="typescript-test-passing-without-junit-fails-naming-it"
workspace "$name" coverage.xml
run_reports stage typescript test node-24 success
if assert_error "$name" "typescript test gate passed but wrote no junit.xml"; then
  if [ "$(staged)" != "coverage-node-24.xml " ]; then
    fail_case "$name" "staged '$(staged)', expected 'coverage-node-24.xml '"
  else
    pass_case "$name"
  fi
fi

# The Rust test gate writes junit.xml through cargo-nextest (vergil-tooling#4395,
# vergil-actions#1216), so a passing Rust test leg holding only coverage.xml
# fails naming junit.xml, and still stages the coverage.xml it has.
name="rust-test-passing-without-junit-fails-naming-it"
workspace "$name" coverage.xml
run_reports stage rust test 1.85 success
if assert_error "$name" "rust test gate passed but wrote no junit.xml"; then
  if grep -F '::error::' <<<"$stderr" | grep -F "coverage.xml" >/dev/null; then
    fail_case "$name" "named a report that exists: ${stderr}"
  elif [ "$(staged)" != "coverage-1.85.xml " ]; then
    fail_case "$name" "staged '$(staged)', expected 'coverage-1.85.xml '"
  else
    pass_case "$name"
  fi
fi

# A failed Rust test leg that wrote no junit.xml only notes it.
name="rust-test-failed-without-junit-notes-it"
workspace "$name" coverage.xml
run_reports stage rust test 1.85 failure
if assert_staged "$name" "coverage-1.85.xml "; then
  if grep -qF "::notice::" <<<"$stdout" && grep -qF "junit.xml" <<<"$stdout"; then
    pass_case "$name"
  else
    fail_case "$name" "no ::notice:: naming junit.xml; stdout: ${stdout}"
  fi
fi

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
run_reports stage python test 3.14 success
if assert_error "$name" "python test gate passed but wrote no junit.xml"; then
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
  run_reports stage python test 3.14 "$outcome"
  if assert_staged "$name" "coverage-3.14.xml "; then
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

# --- a fleet language with no contract warns and stages nothing ---------------

# assert_no_contract_warning <name> <language> <gate> — exit 0, no ::error::,
# and a ::warning:: naming the language and gate.
assert_no_contract_warning() {
  local name="$1" language="$2" gate="$3" warnings
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 1
  fi
  if grep -qF -- "::error::" <<<"${stdout}${stderr}"; then
    fail_case "$name" "raised an ::error::: ${stderr}"
    return 1
  fi
  warnings="$(grep -F -- "::warning::" <<<"${stdout}"$'\n'"${stderr}" || true)"
  if ! grep -qF -- "the ${language} ${gate} gate's reports are not produced yet" \
    <<<"$warnings"; then
    fail_case "$name" "no ::warning:: naming ${language} ${gate}; got '${stdout}${stderr}'"
    return 1
  fi
  return 0
}

for language in go cpp; do
  for gate in test audit; do
    for outcome in success failure; do
      name="no-contract-${language}-${gate}-${outcome}-warns-and-stages-nothing"
      # Report-like files present: none may be staged for a language with no
      # contract, even names another language's contract lists.
      workspace "$name" coverage.xml junit.xml pip-audit.json cargo-deny.json
      run_reports stage "$language" "$gate" 1.0 "$outcome"
      if assert_no_contract_warning "$name" "$language" "$gate"; then
        if [ -e "${ws}/ci-reports" ]; then
          fail_case "$name" "created ci-reports holding '$(staged)'"
        else
          pass_case "$name"
        fi
      fi
    done
  done
done

# The warning path never hides a bad input.
name="no-contract-language-with-empty-version-fails"
workspace "$name"
run_reports stage go test "" success
if assert_error "$name" "VERSION is empty"; then
  pass_case "$name"
fi

name="no-contract-language-with-unsafe-version-fails"
workspace "$name"
run_reports stage cpp audit "a/b" success
if assert_error "$name" "not a single path component"; then
  pass_case "$name"
fi

name="no-contract-language-with-unknown-gate-fails"
workspace "$name"
run_reports stage go quality 1.0 success
if assert_error "$name" "unknown gate 'quality'"; then
  pass_case "$name"
fi

# --- bad input ----------------------------------------------------------------

for language in shell cobol Python; do
  name="unknown-language-'${language}'-fails"
  workspace "unknown-language-${language}" coverage.xml junit.xml
  run_reports stage "$language" test 1.0 success
  if assert_error "$name" "unknown language '${language}'"; then
    if [ -n "$(staged)" ]; then
      fail_case "$name" "staged '$(staged)', expected nothing"
    else
      pass_case "$name"
    fi
  fi
done

name="empty-language-fails"
workspace "$name" coverage.xml junit.xml
run_reports stage "" test 1.0 success
if assert_error "$name" "LANGUAGE is empty"; then
  pass_case "$name"
fi

name="empty-gate-fails"
workspace "$name" coverage.xml junit.xml
run_reports stage python "" 1.0 success
if assert_error "$name" "GATE is empty"; then
  pass_case "$name"
fi

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
case_tools rust test '[{"name":"cargo-llvm-cov"},{"name":"cargo-nextest"}]'
case_tools rust audit '[{"name":"cargo-deny"}]'
case_tools typescript test '[{"name":"vitest"},{"name":"@vitest/coverage-v8"}]'
case_tools typescript audit '[{"name":"npm audit"}]'
case_tools typescript lint '[{"name":"prettier"},{"name":"eslint"}]'
case_tools typescript typecheck '[{"name":"tsc"}]'

# TypeScript has a contract for every gate, so no mode warns for it.
name="typescript-warns-on-no-gate"
ok=1
for gate in test audit lint typecheck; do
  workspace "${name}-${gate}"
  run_reports tools typescript "$gate"
  if [ "$rc" -ne 0 ] || grep -qF -- "::warning::" <<<"${stdout}${stderr}"; then
    fail_case "$name" "tools ${gate}: rc ${rc}, output '${stdout}${stderr}'"
    ok=0
  fi
  workspace "${name}-stage-${gate}" coverage.xml junit.xml npm-audit.json \
    quality-eslint.json quality-tsc.txt
  run_reports stage typescript "$gate" node-24 success
  if [ "$rc" -ne 0 ] || grep -qF -- "::warning::" <<<"${stdout}${stderr}"; then
    fail_case "$name" "stage ${gate}: rc ${rc}, output '${stdout}${stderr}'"
    ok=0
  fi
done
if [ "$ok" -eq 1 ]; then
  pass_case "$name"
fi

# A language with a contract but no report_tools branch is an internal error,
# never a silent empty tools list. Sourced in a child bash, with has_contract
# widened to claim a contract for go/test, which report_tools has no branch
# for.
name="tools-contract-without-tools-branch-fails"
rc=0
stderr="$(bash -c '
  source "$1"
  has_contract() { [ "$1/$2" = go/test ]; }
  report_tools go test
' _ "$reports_sh" 2>&1 >/dev/null)" || rc=$?
if assert_error "$name" "internal: no tools for 'go/test'"; then
  pass_case "$name"
fi

# A fleet language with no contract gets an empty tools list and the warning,
# so the evidence job (the required check) stays green for it.
for language in go cpp; do
  for gate in test audit; do
    name="tools-no-contract-${language}-${gate}-is-empty-with-a-warning"
    workspace "$name"
    run_reports tools "$language" "$gate"
    if assert_no_contract_warning "$name" "$language" "$gate"; then
      if [ "$(cat "$outputs")" = "tools=[]" ]; then
        pass_case "$name"
      else
        fail_case "$name" "expected the output 'tools=[]', got '$(cat "$outputs")'"
      fi
    fi
  done
done

# case_tools_fails <name> <language> <gate> <substring> — an ::error:: and no
# output written.
case_tools_fails() {
  local name="$1"
  workspace "$name"
  run_reports tools "$2" "$3"
  if assert_error "$name" "$4"; then
    if [ -s "$outputs" ]; then
      fail_case "$name" "wrote an output: '$(cat "$outputs")'"
    else
      pass_case "$name"
    fi
  fi
}

case_tools_fails tools-unknown-language-fails shell test "unknown language 'shell'"
case_tools_fails tools-unknown-gate-fails rust quality "unknown gate 'quality'"
case_tools_fails tools-no-contract-unknown-gate-fails go quality "unknown gate 'quality'"

name="tools-without-github-output-fails"
workspace "$name"
rc=0
stderr="$(cd "$ws" && env -u GITHUB_OUTPUT MODE=tools LANGUAGE=rust GATE=test \
  bash "$reports_sh" 2>&1 >/dev/null)" || rc=$?
if assert_error "$name" "GITHUB_OUTPUT is not set"; then
  pass_case "$name"
fi

# --- the quality gate's lint and typecheck legs (#1249) ----------------------

# lint and typecheck are gates of the table, staged like test and audit.
name="lint-and-typecheck-are-gates"
ok=1
for gate in lint typecheck; do
  workspace "${name}-${gate}" quality-ruff.json quality-mypy.xml
  run_reports stage python "$gate" 3.14 success
  if [ "$rc" -ne 0 ] || grep -qF "unknown gate" <<<"$stderr"; then
    fail_case "$name" "${gate} is not a gate: rc ${rc}, stderr ${stderr}"
    ok=0
  fi
done
if [ "$ok" -eq 1 ]; then
  pass_case "$name"
fi

case_stage python-lint-stages-ruff python lint \
  "quality-ruff-1.0.json " quality-ruff.json quality-mypy.xml
case_stage python-typecheck-stages-mypy python typecheck \
  "quality-mypy-1.0.xml " quality-ruff.json quality-mypy.xml
case_stage rust-lint-stages-clippy rust lint \
  "quality-clippy-1.0.json " quality-clippy.json quality-cargo-check.json
case_stage rust-typecheck-stages-cargo-check rust typecheck \
  "quality-cargo-check-1.0.json " quality-clippy.json quality-cargo-check.json
case_stage typescript-lint-stages-eslint typescript lint \
  "quality-eslint-1.0.json " quality-eslint.json quality-tsc.txt
case_stage typescript-typecheck-stages-tsc typescript typecheck \
  "quality-tsc-1.0.txt " quality-eslint.json quality-tsc.txt

# case_tools_named <name> <language> <gate> <expected JSON>
case_tools_named() {
  local name="$1" actual
  workspace "$name"
  run_reports tools "$2" "$3"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 0
  fi
  actual="$(sed -n 's/^tools=//p' "$outputs")"
  if jq -e --argjson a "$actual" --argjson e "$4" -n '$a == $e' >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name" "expected $4, got '${actual}'"
  fi
}

# rust_lint_files_and_tools / rust_typecheck_files_and_tools: the file names
# are vergil-tooling's CLIPPY_REPORT and CARGO_CHECK_REPORT (#4473).
name="rust-lint-files-and-tools"
workspace "$name" quality-clippy.json
run_reports stage rust lint 1.99 success
if assert_staged "$name" "quality-clippy-1.99.json "; then
  case_tools_named "$name" rust lint '[{"name":"rustfmt"},{"name":"clippy"}]'
fi
name="rust-typecheck-files-and-tools"
workspace "$name" quality-cargo-check.json
run_reports stage rust typecheck 1.99 success
if assert_staged "$name" "quality-cargo-check-1.99.json "; then
  case_tools_named "$name" rust typecheck '[{"name":"cargo"}]'
fi

# Python's lint and typecheck evidence is what ci-quality.yml hardcoded before
# #1249: the files quality-ruff-<version>.json and quality-mypy-<version>.xml,
# and the tools vrg-validate-common, vrg-validate-custom, ruff, mypy.
name="python-lint-matches-today"
workspace "$name" quality-ruff.json quality-mypy.xml
run_reports stage python lint 3.13 success
lint_staged="$(staged)"
run_reports stage python typecheck 3.13 success
both_staged="$(staged)"
lint_tools="$(
  run_reports tools python lint
  sed -n 's/^tools=//p' "$outputs"
)"
typecheck_tools="$(
  run_reports tools python typecheck
  sed -n 's/^tools=//p' "$outputs"
)"
today='[{"name": "vrg-validate-common"}, {"name": "vrg-validate-custom"}, {"name": "ruff"}, {"name": "mypy"}]'
if [ "$lint_staged" != "quality-ruff-3.13.json " ] ||
  [ "$both_staged" != "quality-mypy-3.13.xml quality-ruff-3.13.json " ]; then
  fail_case "$name" "staged '${lint_staged}' then '${both_staged}'"
elif ! jq -e -n --argjson l "$lint_tools" --argjson t "$typecheck_tools" \
  --argjson e "$today" \
  '([{"name": "vrg-validate-common"}, {"name": "vrg-validate-custom"}] + $l + $t) == $e' \
  >/dev/null; then
  fail_case "$name" "tools ${lint_tools} + ${typecheck_tools} differ from today's ${today}"
else
  pass_case "$name"
fi

# A passing leg with no report fails, for each of the six entries.
for entry in python/lint:quality-ruff.json python/typecheck:quality-mypy.xml \
  rust/lint:quality-clippy.json rust/typecheck:quality-cargo-check.json \
  typescript/lint:quality-eslint.json typescript/typecheck:quality-tsc.txt; do
  pair="${entry%%:*}"
  file="${entry#*:}"
  language="${pair%%/*}"
  gate="${pair#*/}"
  name="passing-${language}-${gate}-leg-missing-report-fails"
  workspace "$name"
  run_reports stage "$language" "$gate" 1.0 success
  if assert_error "$name" "${language} ${gate} gate passed but wrote no ${file}"; then
    pass_case "$name"
  fi
  name="passing-${language}-${gate}-leg-empty-report-fails"
  workspace "$name"
  : >"${ws}/${file}"
  run_reports stage "$language" "$gate" 1.0 success
  if assert_error "$name" "wrote no ${file}"; then
    if [ -n "$(staged)" ]; then
      fail_case "$name" "staged '$(staged)'"
    else
      pass_case "$name"
    fi
  fi
done

# A failing leg's missing report is not an extra failure: the step passes,
# and the leg's own failure stands.
for pair in python/lint rust/lint typescript/lint python/typecheck \
  rust/typecheck typescript/typecheck; do
  language="${pair%%/*}"
  gate="${pair#*/}"
  name="failing-${language}-${gate}-leg-missing-report-not-extra-error"
  workspace "$name"
  run_reports stage "$language" "$gate" 1.0 failure
  if assert_staged "$name" ""; then
    if grep -qF "::error::" <<<"$stderr"; then
      fail_case "$name" "raised an ::error::: ${stderr}"
    elif ! grep -qF "::notice::" <<<"$stdout"; then
      fail_case "$name" "no ::notice:: for the missing report; stdout: ${stdout}"
    else
      pass_case "$name"
    fi
  fi
done

# A primary language with no quality contract warns, as for test and audit.
for language in go cpp; do
  for gate in lint typecheck; do
    name="no-contract-${language}-${gate}-warns-and-stages-nothing"
    workspace "$name" quality-ruff.json quality-mypy.xml quality-clippy.json
    run_reports stage "$language" "$gate" 1.0 success
    if assert_no_contract_warning "$name" "$language" "$gate"; then
      if [ -e "${ws}/ci-reports" ]; then
        fail_case "$name" "created ci-reports holding '$(staged)'"
      else
        pass_case "$name"
      fi
    fi
    name="tools-no-contract-${language}-${gate}-is-empty-with-a-warning"
    workspace "$name"
    run_reports tools "$language" "$gate"
    if assert_no_contract_warning "$name" "$language" "$gate"; then
      if [ "$(cat "$outputs")" = "tools=[]" ]; then
        pass_case "$name"
      else
        fail_case "$name" "expected the output 'tools=[]', got '$(cat "$outputs")'"
      fi
    fi
  done
done

# assert_no_language_notice <name> <gate> — exit 0, no ::error:: or
# ::warning::, and the ::notice:: for a non-primary language's quality leg.
assert_no_language_notice() {
  local name="$1" gate="$2"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 1
  fi
  if grep -qE -- "::(error|warning)::" <<<"${stdout}${stderr}"; then
    fail_case "$name" "raised an error or warning: ${stderr}"
    return 1
  fi
  if ! grep -F -- "::notice::" <<<"$stderr" |
    grep -qF -- "is not a fleet primary language" ||
    ! grep -qF -- "its ${gate} leg has no report contract" <<<"$stderr"; then
    fail_case "$name" "no ::notice:: for the ${gate} leg; got '${stderr}'"
    return 1
  fi
  return 0
}

# ci-quality serves repositories with no fleet primary language (shell, a
# Claude plugin, none): their quality legs note it and stage nothing.
for language in shell claude-plugin ""; do
  for gate in lint typecheck; do
    name="no-language-'${language}'-${gate}-notes-and-stages-nothing"
    workspace "no-language-${language:-none}-${gate}" quality-ruff.json
    run_reports stage "$language" "$gate" latest success
    if assert_no_language_notice "$name" "$gate"; then
      if [ -e "${ws}/ci-reports" ]; then
        fail_case "$name" "created ci-reports holding '$(staged)'"
      else
        pass_case "$name"
      fi
    fi
    name="tools-no-language-'${language}'-${gate}-is-empty"
    workspace "tools-no-language-${language:-none}-${gate}"
    run_reports tools "$language" "$gate"
    if assert_no_language_notice "$name" "$gate"; then
      if [ "$(cat "$outputs")" = "tools=[]" ]; then
        pass_case "$name"
      else
        fail_case "$name" "expected the output 'tools=[]', got '$(cat "$outputs")'"
      fi
    fi
  done
done

# The test and audit gates still refuse such a language.
name="shell-test-gate-still-fails"
workspace "$name"
run_reports stage shell test 1.0 success
if assert_error "$name" "unknown language 'shell'"; then
  pass_case "$name"
fi

# --- expect mode --------------------------------------------------------------

# run_expect <language> <dir> — run reports.sh in expect mode in $ws, with no
# GATE.
run_expect() {
  local err out
  err="$(mktemp)"
  out="$(mktemp)"
  rc=0
  (
    cd "$ws"
    env -u GATE MODE=expect LANGUAGE="$1" REPORTS_DIR="$2" bash "$reports_sh"
  ) >"$out" 2>"$err" || rc=$?
  stderr="$(cat "$err")"
  stdout="$(cat "$out")"
  rm -f "$err" "$out"
}

# reports_dir <file>... — $ws/evidence-reports holding each named file.
reports_dir() {
  local f
  mkdir -p "${ws}/evidence-reports"
  for f in "$@"; do
    printf '%s\n' "$f" >"${ws}/evidence-reports/${f}"
  done
}

name="expect-rust-finds-both-reports"
workspace "$name"
reports_dir quality-common.log quality-custom.log quality-clippy-1.99.json \
  quality-cargo-check-1.99.json
run_expect rust evidence-reports
if [ "$rc" -ne 0 ]; then
  fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
else
  rm "${ws}/evidence-reports/quality-clippy-1.99.json"
  run_expect rust evidence-reports
  if assert_error "$name" "no rust lint leg staged its quality-clippy.json"; then
    if grep -F '::error::' <<<"$stderr" | grep -qF "quality-cargo-check.json"; then
      fail_case "$name" "named a report that exists: ${stderr}"
    else
      pass_case "$name"
    fi
  fi
fi

name="expect-rust-missing-both-names-each"
workspace "$name"
reports_dir quality-common.log
run_expect rust evidence-reports
if assert_error "$name" "its quality-clippy.json" "its quality-cargo-check.json"; then
  pass_case "$name"
fi

# A report must be version-suffixed and non-empty to count.
name="expect-unsuffixed-or-empty-report-is-missing"
workspace "$name"
reports_dir quality-clippy.json
: >"${ws}/evidence-reports/quality-cargo-check-1.99.json"
run_expect rust evidence-reports
if assert_error "$name" "its quality-clippy.json" "its quality-cargo-check.json"; then
  pass_case "$name"
fi

name="expect-python-matches-today"
workspace "$name"
reports_dir quality-common.log quality-custom.log quality-ruff-3.13.json \
  quality-ruff-3.14.json quality-mypy-3.13.xml quality-mypy-3.14.xml
run_expect python evidence-reports
if [ "$rc" -ne 0 ]; then
  fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
else
  rm "${ws}/evidence-reports/quality-mypy-3.13.xml" \
    "${ws}/evidence-reports/quality-mypy-3.14.xml"
  run_expect python evidence-reports
  if assert_error "$name" "no python typecheck leg staged its quality-mypy.xml"; then
    pass_case "$name"
  fi
fi

# Rust's reports are never satisfied by Python's names.
# TypeScript's lint leg runs once and its typecheck leg once (one version
# label each); expect mode requires both reports and warns for neither.
name="expect-typescript-finds-both-reports"
workspace "$name"
reports_dir quality-common.log quality-custom.log quality-eslint-node-24.json \
  quality-tsc-node-24.txt
run_expect typescript evidence-reports
if [ "$rc" -ne 0 ] || grep -qF -- "::warning::" <<<"${stdout}${stderr}"; then
  fail_case "$name" "expected exit 0 and no warning, got ${rc}; stderr: ${stderr}"
else
  rm "${ws}/evidence-reports/quality-tsc-node-24.txt"
  run_expect typescript evidence-reports
  if assert_error "$name" "no typescript typecheck leg staged its quality-tsc.txt"; then
    if grep -F '::error::' <<<"$stderr" | grep -qF "quality-eslint.json"; then
      fail_case "$name" "named a report that exists: ${stderr}"
    else
      pass_case "$name"
    fi
  fi
fi

name="expect-typescript-ignores-other-names"
workspace "$name"
reports_dir quality-ruff-1.0.json quality-mypy-1.0.xml quality-clippy-1.0.json \
  quality-cargo-check-1.0.json
run_expect typescript evidence-reports
if assert_error "$name" "its quality-eslint.json" "its quality-tsc.txt"; then
  pass_case "$name"
fi

name="expect-rust-ignores-python-names"
workspace "$name"
reports_dir quality-ruff-1.99.json quality-mypy-1.99.xml
run_expect rust evidence-reports
if assert_error "$name" "its quality-clippy.json" "its quality-cargo-check.json"; then
  pass_case "$name"
fi

for language in go cpp; do
  name="expect-no-contract-${language}-warns"
  workspace "$name"
  reports_dir quality-common.log
  run_expect "$language" evidence-reports
  if assert_no_contract_warning "$name" "$language" lint &&
    assert_no_contract_warning "$name" "$language" typecheck; then
    pass_case "$name"
  fi
done

for language in shell claude-plugin ""; do
  name="expect-no-language-'${language}'-notes"
  workspace "expect-no-language-${language:-none}"
  reports_dir quality-common.log
  run_expect "$language" evidence-reports
  if assert_no_language_notice "$name" lint &&
    assert_no_language_notice "$name" typecheck; then
    pass_case "$name"
  fi
done

name="expect-empty-reports-dir-fails"
workspace "$name"
run_expect rust ""
if assert_error "$name" "REPORTS_DIR is empty"; then
  pass_case "$name"
fi

name="expect-missing-reports-dir-fails"
workspace "$name"
run_expect python evidence-reports
if assert_error "$name" "REPORTS_DIR 'evidence-reports' is not a directory"; then
  pass_case "$name"
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
    grep -qE '(pip-audit|licenses|cargo-deny|npm-audit|coverage|junit)[-.*]'; then
    fail_case "$name" "names a report file outside the action"
    return 0
  fi
  pass_case "$name"
}

case_workflow ci-test.yml test
case_workflow ci-audit.yml audit

# ci-quality.yml: the lint and typecheck legs stage through the action with
# their gate step's outcome, the evidence job requires the reports (expect
# mode) and takes its tools from the action, the emit step takes every
# staged quality-* file, and no step names a lint or typecheck report or tool.
name="ci-quality.yml-stages-through-ci-evidence-reports"
wf="${repo_root}/.github/workflows/ci-quality.yml"
code="$(sed -E 's/(^|[[:space:]])#.*//' "$wf")"
if [ "$(grep -cE '^ +uses: \./actions/ci/evidence/reports$' <<<"$code")" -lt 5 ]; then
  fail_case "$name" "the stage, expect and tools steps do not all use the action"
elif [ "$(grep -cE '^ +gate-outcome: \$\{\{ steps\.gate\.outcome \}\}$' <<<"$code")" -ne 2 ] ||
  [ "$(grep -cE '^ +id: gate$' <<<"$code")" -ne 2 ]; then
  fail_case "$name" "the lint and typecheck stage steps do not take their gate step's outcome"
elif [ "$(grep -cE '^ +gate: lint$' <<<"$code")" -ne 2 ] ||
  [ "$(grep -cE '^ +gate: typecheck$' <<<"$code")" -ne 2 ]; then
  fail_case "$name" "lint and typecheck are not each named in a stage and a tools step"
elif ! grep -qE '^ +mode: expect$' <<<"$code" ||
  ! grep -qE '^ +reports-dir: evidence-reports$' <<<"$code"; then
  fail_case "$name" "the evidence job does not require the reports"
elif ! grep -qE '^ +files: evidence-reports/quality-\*$' <<<"$code"; then
  fail_case "$name" "the emit step does not take evidence-reports/quality-*"
elif ! grep -qE '^ +tools: \$\{\{ steps\.tools\.outputs\.tools \}\}$' <<<"$code"; then
  fail_case "$name" "the emit step does not take the combined tools"
elif grep -qE '(ruff|mypy|clippy|cargo-check|rustfmt|eslint|prettier|tsc)' <<<"$code"; then
  fail_case "$name" "names a lint or typecheck report or tool outside the action"
else
  pass_case "$name"
fi

printf '\nreports.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
