#!/usr/bin/env bash
#
# Behavioural test for reports.sh — the per-language report-file contract of
# the test and audit evidence gates and of the quality gate's lint and
# typecheck legs, the staging of one leg's reports, and expect mode's check of
# the quality evidence job's reports (issues #1211, #1249, #1260).
#
# Framework-free and developer-runnable: `bash reports.test.sh`. CI runs it
# from .github/workflows/smoke-setup-vergil.yml. It needs only bash and
# coreutils, plus jq for the tools-JSON and skip-record cases and git for the
# not-bootstrapped cases (#1294), which run in scratch git repositories with
# a vrg-validate record written by hand.
#
# Each stage case runs reports.sh in a scratch workspace holding chosen report
# files, then asserts the exit status, the staged file names and contents, and
# for the failure cases the `::error::` annotation naming each missing report.
# A fleet language with no contract (go, cpp) must warn, stage nothing and
# list no tools, while every bad input still fails. TypeScript has a contract
# for every gate (epic vergil-project/.github#1174) and warns on none. A repository
# with no fleet primary language (shell, a Claude plugin, none) gets a notice
# on its lint and typecheck legs instead. Tools mode, given the downloaded
# legs, lists no tools for a gate whose legs left skip records (#1406). The
# final cases check that
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
  "licenses-1.0.json npm-audit-1.0.json " npm-audit.json licenses.json \
  coverage.xml junit.xml

# TypeScript's audit reports are npm-audit.json and licenses.json, never
# another language's names: a workspace holding only Python's and Rust's own
# audit reports fails a passing TypeScript audit, naming both.
name="typescript-audit-ignores-other-names"
workspace "$name" pip-audit.json cargo-deny.json
run_reports stage typescript audit node-24 success
if assert_error "$name" \
  "typescript audit gate passed but wrote no npm-audit.json" \
  "typescript audit gate passed but wrote no licenses.json"; then
  if [ -n "$(staged)" ]; then
    fail_case "$name" "staged '$(staged)', expected nothing"
  else
    pass_case "$name"
  fi
fi

# A passing TypeScript audit leg that wrote npm-audit.json but no
# licenses.json (a vergil-tooling release without vrg-npm-license-gate) fails
# naming licenses.json, and still stages the npm-audit.json it has.
name="typescript-audit-requires-licenses"
workspace "$name" npm-audit.json
run_reports stage typescript audit node-24 success
if assert_error "$name" "typescript audit gate passed but wrote no licenses.json"; then
  if grep -F '::error::' <<<"$stderr" | grep -F "npm-audit.json" >/dev/null; then
    fail_case "$name" "named a report that exists: ${stderr}"
  elif [ "$(staged)" != "npm-audit-node-24.json " ]; then
    fail_case "$name" "staged '$(staged)', expected 'npm-audit-node-24.json '"
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
case_tools typescript audit '[{"name":"npm audit"},{"name":"vrg-npm-license-gate"}]'
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
    licenses.json quality-eslint.json quality-tsc.txt
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
  if ! grep -qF -- "is not a fleet primary language" <<<"$(grep -F -- "::notice::" <<<"$stderr")" ||
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

# --- a gate skipped as not bootstrapped (#1294) --------------------------------

# git_ws <name> — a fresh workspace that is a git repository with one commit
# (a README only: no manifest, no source). Sets ws.
git_ws() {
  workspace "$1"
  (
    cd "$ws"
    git init -q
    printf 'readme\n' >README.md
    git add README.md
    git -c user.name=test -c user.email=test@example.invalid \
      -c commit.gpgsign=false commit -q -m init
  )
}

# record <exit-code> <stage>=<status>[=<skip-json>]... — write $ws's
# vrg-validate record for the workspace's HEAD, as vrg-validate writes it,
# each stage with its `skip` when one is given (vergil-tooling#5034).
record() {
  local exit_code="$1" stage name rest entry stages="" head
  shift
  for stage in "$@"; do
    name="${stage%%=*}"
    rest="${stage#*=}"
    entry="{\"name\": \"${name}\", \"status\": \"${rest%%=*}\""
    if [[ "$rest" == *=* ]]; then
      entry="${entry}, \"skip\": ${rest#*=}"
    fi
    stages="${stages:+${stages}, }${entry}}"
  done
  head="$(git -C "$ws" rev-parse HEAD)"
  mkdir -p "${ws}/.vergil"
  printf '{"head": "%s", "exit_code": %s, "full": false, "clean_at_start": true, "stages": [%s]}\n' \
    "$head" "$exit_code" "$stages" >"${ws}/.vergil/vrg-validate-last.json"
}

# manifests_of <language> — the manifests vrg-validate names missing for a
# repository of the language with none of them, as a JSON array.
manifests_of() {
  case "$1" in
    python) echo '["pyproject.toml","uv.lock"]' ;;
    rust) echo '["Cargo.toml","Cargo.lock"]' ;;
    typescript) echo '["package.json","package-lock.json"]' ;;
  esac
}

# nb <language> [manifests-json] — the not-bootstrapped `skip` vrg-validate
# records on each stage it skipped, as JSON.
nb() {
  printf '{"reason": "not-bootstrapped", "language": "%s", "missing_manifests": %s}' \
    "$1" "${2:-$(manifests_of "$1")}"
}

# skip_stages <language> <gate> — the stages a not-bootstrapped
# `vrg-validate --check <gate>` records, each `warn` with its skip.
skip_stages() {
  local skip
  skip="$(nb "$1")"
  if [ "$1" = typescript ]; then
    printf '%s\n' "install=warn=${skip}" "typescript-tools=warn=${skip}" \
      "$2=warn=${skip}"
  else
    printf '%s\n' "install=warn=${skip}" "$2=warn=${skip}"
  fi
}

# marker_of <gate> <version> — the skip record's basename.
marker_of() {
  case "$1" in
    lint | typecheck) echo "quality-$1-not-bootstrapped-$2.json" ;;
    *) echo "$1-not-bootstrapped-$2.json" ;;
  esac
}

# has_notice <text> <substring>... — one ::notice line of <text> holds every
# substring.
has_notice() {
  local text="$1" line needle ok
  shift
  while IFS= read -r line; do
    [[ "$line" == *"::notice"* ]] || continue
    ok=1
    for needle in "$@"; do
      [[ "$line" == *"$needle"* ]] || ok=0
    done
    [ "$ok" -eq 0 ] || return 0
  done <<<"$text"
  return 1
}

# assert_skipped <name> <language> <gate> <version> <manifests-json> — exit 0,
# only the skip record staged, holding the leg, and a notice naming the leg
# and the reason.
assert_skipped() {
  local name="$1" language="$2" gate="$3" version="$4" manifests="$5" marker
  marker="$(marker_of "$gate" "$version")"
  assert_staged "$name" "${marker} " || return 1
  if ! jq -e --arg g "$gate" --arg l "$language" --arg v "$version" \
    --argjson m "$manifests" \
    '.skipped == true and .reason == "not-bootstrapped" and .gate == $g and
      .language == $l and .version == $v and .missing_manifests == $m and
      (.head | test("^[0-9a-f]{40}$"))' "${ws}/ci-reports/${marker}" >/dev/null; then
    fail_case "$name" "unexpected skip record: $(cat "${ws}/ci-reports/${marker}")"
    return 1
  fi
  if ! has_notice "$stdout" \
    "the ${language} ${gate} leg ${version} wrote no reports" \
    "not bootstrapped yet"; then
    fail_case "$name" "expected a notice naming the leg and the reason, got '${stdout}'"
    return 1
  fi
  if grep -qF "::error::" <<<"$stderr"; then
    fail_case "$name" "unexpected error: ${stderr}"
    return 1
  fi
  return 0
}

for language in python rust typescript; do
  manifests="$(manifests_of "$language")"
  for gate in test audit lint typecheck; do
    name="not-bootstrapped-${language}-${gate}-skips-loudly"
    git_ws "$name"
    mapfile -t stages < <(skip_stages "$language" "$gate")
    record 0 "${stages[@]}"
    run_reports stage "$language" "$gate" 1.0 success
    if assert_skipped "$name" "$language" "$gate" 1.0 "$manifests"; then
      pass_case "$name"
    fi
  done
done

# vrg-github-repo-init writes a TypeScript repo's package.json with no
# dependency and no lockfile; vergil-tooling counts it as not bootstrapped and
# names only the lockfile missing. The skip record carries the manifests the
# vrg-validate record gives.
name="not-bootstrapped-typescript-dependency-free-package-json-skips"
git_ws "$name"
printf '{"name": "x", "version": "0.1.0", "private": true}\n' >"${ws}/package.json"
skip="$(nb typescript '["package-lock.json"]')"
record 0 "install=warn=${skip}" "typescript-tools=warn=${skip}" "test=warn=${skip}"
run_reports stage typescript test node-24 success
if assert_skipped "$name" typescript test node-24 '["package-lock.json"]'; then
  pass_case "$name"
fi

# assert_not_skipped <name> <substring>... — the leg fails, stages no skip
# record, and its errors hold each substring and the missing-report error.
assert_not_skipped() {
  local name="$1"
  shift
  assert_error "$name" "$@" "gate passed but wrote no" || return 1
  case "$(staged)" in
    *not-bootstrapped*)
      fail_case "$name" "staged a skip record: $(staged)"
      return 1
      ;;
  esac
  return 0
}

# A record of a vergil-tooling release before vergil-tooling#5034 gives the
# skipped stages `warn` with no skip; a warning is never taken for a skip.
name="not-bootstrapped-warn-stages-with-no-skip-fail"
git_ws "$name"
record 0 install=warn test=warn
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "records stages warn with no skip (install, test)" \
  "vergil-tooling#5034"; then
  pass_case "$name"
fi

# Only the gate's stage carrying its skip is not enough: every stage must.
name="not-bootstrapped-one-stage-with-no-skip-fails"
git_ws "$name"
record 0 install=warn "test=warn=$(nb python)"
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "records stages warn with no skip (install)"; then
  pass_case "$name"
fi

name="not-bootstrapped-skip-of-another-language-fails"
git_ws "$name"
record 0 "install=warn=$(nb python)" "test=warn=$(nb python)"
run_reports stage rust test 1.99 success
if assert_not_skipped "$name" \
  "records stages skipped other than as a rust repo not bootstrapped" \
  'test ({"reason":"not-bootstrapped","language":"python"'; then
  pass_case "$name"
fi

name="not-bootstrapped-skip-of-another-reason-fails"
git_ws "$name"
skip='{"reason": "something-else", "language": "python", "missing_manifests": ["uv.lock"]}'
record 0 "install=warn=${skip}" "test=warn=${skip}"
run_reports stage python test 3.14 success
if assert_not_skipped "$name" \
  "records stages skipped other than as a python repo not bootstrapped" \
  '"reason":"something-else"'; then
  pass_case "$name"
fi

for skip in '"not-bootstrapped"' \
  '{"reason": "not-bootstrapped", "language": "python", "missing_manifests": []}' \
  '{"reason": "not-bootstrapped", "language": "python", "missing_manifests": [""]}' \
  '{"reason": "not-bootstrapped", "language": "python", "missing_manifests": "uv.lock"}' \
  '{"reason": "not-bootstrapped", "language": "python"}'; do
  name="not-bootstrapped-malformed-skip-fails ($skip)"
  git_ws "not-bootstrapped-malformed-skip-$((pass + fail))"
  record 0 "install=warn=$(nb python)" "test=warn=${skip}"
  run_reports stage python test 3.14 success
  if assert_not_skipped "$name" \
    "records stages skipped other than as a python repo not bootstrapped (test ("; then
    pass_case "$name"
  fi
done

name="not-bootstrapped-unreadable-record-fails"
git_ws "$name"
record 0 "install=warn=$(nb python)" "test=warn=$(nb python)"
printf 'not json\n' >"${ws}/.vergil/vrg-validate-last.json"
run_reports stage python test 3.14 success
if assert_error "$name" "cannot read the vrg-validate record"; then
  pass_case "$name"
fi

name="not-bootstrapped-record-of-another-commit-fails"
git_ws "$name"
mapfile -t stages < <(skip_stages python test)
record 0 "${stages[@]}"
(
  cd "$ws"
  git -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m later
)
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "not the checked-out"; then
  pass_case "$name"
fi

name="not-bootstrapped-record-of-a-failed-run-fails"
git_ws "$name"
mapfile -t stages < <(skip_stages python test)
record 1 "${stages[@]}"
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "shows the run exited 1"; then
  pass_case "$name"
fi

name="not-bootstrapped-record-with-a-stage-that-ran-fails"
git_ws "$name"
record 0 install=ok "test=warn=$(nb python)"
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "shows stages that ran (install (ok))"; then
  pass_case "$name"
fi

# A bootstrapped gate (its stage `ok`) that wrote no report fails exactly as
# before, with no word about a skip.
name="recorded-ok-gate-with-no-report-fails-as-before"
git_ws "$name"
record 0 install=ok test=ok
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "wrote no coverage.xml" "wrote no junit.xml"; then
  if grep -qF "bootstrap" <<<"$stderr"; then
    fail_case "$name" "mentions a skip: ${stderr}"
  else
    pass_case "$name"
  fi
fi

# A gate that wrote some of its reports was not skipped, whatever the record.
name="recorded-warn-gate-with-some-reports-fails-as-before"
git_ws "$name"
printf 'coverage\n' >"${ws}/coverage.xml"
record 0 "install=warn=$(nb python)" "test=warn=$(nb python)"
run_reports stage python test 3.14 success
if assert_not_skipped "$name" "wrote no junit.xml"; then
  pass_case "$name"
fi

name="not-bootstrapped-failed-gate-only-notes"
git_ws "$name"
record 1 "install=warn=$(nb python)" "test=warn=$(nb python)"
run_reports stage python test 3.14 failure
if [ "$rc" -ne 0 ]; then
  fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
elif [ -n "$(staged)" ]; then
  fail_case "$name" "staged $(staged)"
else
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
    if grep -qF "quality-cargo-check.json" <<<"$(grep -F '::error::' <<<"$stderr")"; then
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
    if grep -qF "quality-eslint.json" <<<"$(grep -F '::error::' <<<"$stderr")"; then
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

# Rust's reports are never satisfied by Python's names.
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

# skip_record <language> <gate> <version> — $ws/evidence-reports holding the
# leg's skip record, as stage mode writes it.
skip_record() {
  mkdir -p "${ws}/evidence-reports"
  jq -n --arg g "$2" --arg l "$1" --arg v "$3" \
    '{gate: $g, language: $l, version: $v, skipped: true,
      reason: "not-bootstrapped", head: "0000000000000000000000000000000000000000",
      missing_manifests: ["pyproject.toml", "uv.lock"]}' \
    >"${ws}/evidence-reports/$(marker_of "$2" "$3")"
}

name="expect-not-bootstrapped-legs-pass-with-a-notice"
workspace "$name"
reports_dir quality-common.log quality-custom.log
skip_record python lint 3.14
skip_record python typecheck 3.13
skip_record python typecheck 3.14
run_expect python evidence-reports
if [ "$rc" -ne 0 ]; then
  fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
elif ! has_notice "$stdout" "python lint legs were skipped" \
  "quality-lint-not-bootstrapped-3.14.json"; then
  fail_case "$name" "expected a lint skip notice, got '${stdout}'"
elif ! has_notice "$stdout" "python typecheck legs were skipped"; then
  fail_case "$name" "expected a typecheck skip notice, got '${stdout}'"
else
  pass_case "$name"
fi

# A skip record excuses only its own gate's reports.
name="expect-skip-record-excuses-only-its-gate"
workspace "$name"
reports_dir quality-common.log
skip_record rust lint 1.99
run_expect rust evidence-reports
if assert_error "$name" "its quality-cargo-check.json"; then
  if grep -qF "quality-clippy.json" <<<"$(grep -F '::error::' <<<"$stderr")"; then
    fail_case "$name" "named the skipped gate's report: ${stderr}"
  else
    pass_case "$name"
  fi
fi

name="expect-skip-record-beside-a-report-fails"
workspace "$name"
reports_dir quality-ruff-3.13.json quality-mypy-3.13.xml quality-mypy-3.14.xml
skip_record python lint 3.14
run_expect python evidence-reports
if assert_error "$name" "holds both a python lint skip record and the report"; then
  pass_case "$name"
fi

name="expect-skip-record-of-another-language-fails"
workspace "$name"
reports_dir quality-clippy-1.99.json
skip_record python typecheck 1.99
mv "${ws}/evidence-reports/$(marker_of typecheck 1.99)" \
  "${ws}/evidence-reports/quality-typecheck-not-bootstrapped-x.json"
run_expect rust evidence-reports
if assert_error "$name" "is not a rust typecheck skip record"; then
  pass_case "$name"
fi

name="expect-malformed-skip-record-fails"
workspace "$name"
reports_dir quality-eslint-node-24.json
printf 'not json\n' >"${ws}/evidence-reports/quality-typecheck-not-bootstrapped-node-24.json"
run_expect typescript evidence-reports
if assert_error "$name" "is not a typescript typecheck skip record"; then
  pass_case "$name"
fi

# --- tools mode with the downloaded legs (#1406) -----------------------------

# run_tools_dir <language> <gate> <reports-dir> — tools mode in $ws with
# REPORTS_DIR set.
run_tools_dir() {
  local err out
  err="$(mktemp)"
  out="$(mktemp)"
  outputs="${ws}/github-output"
  : >"$outputs"
  rc=0
  (
    cd "$ws"
    GITHUB_OUTPUT="$outputs" MODE=tools LANGUAGE="$1" GATE="$2" \
      REPORTS_DIR="$3" bash "$reports_sh"
  ) >"$out" 2>"$err" || rc=$?
  stderr="$(cat "$err")"
  stdout="$(cat "$out")"
  rm -f "$err" "$out"
}

# assert_tools_output <name> <expected JSON> — exit 0 and exactly this tools
# output.
assert_tools_output() {
  local actual
  actual="$(sed -n 's/^tools=//p' "$outputs")"
  if [ "$rc" -ne 0 ]; then
    fail_case "$1" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 1
  fi
  if [ "$actual" != "$2" ]; then
    fail_case "$1" "expected tools '$2', got '${actual}'"
    return 1
  fi
  return 0
}

for gate in test audit; do
  name="tools-not-bootstrapped-${gate}-legs-list-no-tools"
  workspace "$name"
  skip_record python "$gate" 3.13
  skip_record python "$gate" 3.14
  run_tools_dir python "$gate" evidence-reports
  if assert_tools_output "$name" '[]'; then
    if has_notice "$stderr" "python ${gate} legs were skipped" \
      "$(marker_of "$gate" 3.13)" "lists none of their tools"; then
      pass_case "$name"
    else
      fail_case "$name" "expected a skip notice, got '${stderr}'"
    fi
  fi
done

# Only the skipped quality leg loses its tools; the other leg keeps its own.
name="tools-not-bootstrapped-quality-leg-lists-no-tools"
workspace "$name"
reports_dir quality-common.log quality-custom.log quality-mypy-3.14.xml
skip_record python lint 3.14
run_tools_dir python lint evidence-reports
if assert_tools_output "$name" '[]'; then
  run_tools_dir python typecheck evidence-reports
  if assert_tools_output "$name" '[{"name":"mypy"}]'; then
    pass_case "$name"
  fi
fi

name="tools-with-reports-lists-the-gate-tools"
workspace "$name"
reports_dir cargo-deny-1.99.json
run_tools_dir rust audit evidence-reports
if assert_tools_output "$name" '[{"name":"cargo-deny"}]'; then
  if grep -qF -- "::notice" <<<"$stderr"; then
    fail_case "$name" "unexpected notice: ${stderr}"
  else
    pass_case "$name"
  fi
fi

name="tools-skip-record-beside-a-report-fails"
workspace "$name"
reports_dir coverage-3.13.xml junit-3.13.xml
skip_record python test 3.14
run_tools_dir python test evidence-reports
if assert_error "$name" "holds both a python test skip record and the report"; then
  if [ -s "$outputs" ]; then
    fail_case "$name" "wrote an output: $(cat "$outputs")"
  else
    pass_case "$name"
  fi
fi

name="tools-skip-record-of-another-language-fails"
workspace "$name"
skip_record python test 1.99
run_tools_dir rust test evidence-reports
if assert_error "$name" "is not a rust test skip record"; then
  pass_case "$name"
fi

name="tools-missing-reports-dir-fails"
workspace "$name"
run_tools_dir python test evidence-reports
if assert_error "$name" "REPORTS_DIR 'evidence-reports' is not a directory"; then
  pass_case "$name"
fi

# A language with no contract stages nothing, so its legs may upload no
# partial and the download directory may not exist: tools mode still gives
# the empty list with the warning.
name="tools-no-contract-without-reports-dir-is-empty-with-a-warning"
workspace "$name"
run_tools_dir go test evidence-reports
if assert_tools_output "$name" '[]' &&
  assert_no_contract_warning "$name" go test; then
  pass_case "$name"
fi

name="tools-unknown-gate-with-reports-dir-fails"
workspace "$name"
reports_dir quality-common.log
run_tools_dir rust quality evidence-reports
if assert_error "$name" "unknown gate 'quality'"; then
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
  # The tools step reads the downloaded legs, so skipped legs list no tools
  # (#1406).
  if ! grep -qE '^ +reports-dir: evidence-reports$' "$wf"; then
    fail_case "$name" "the tools step does not read the downloaded legs (reports-dir)"
    return 0
  fi
  if grep -qE '(pip-audit|licenses|cargo-deny|npm-audit|coverage|junit)[-.*]' <<<"$(sed -E 's/(^|[[:space:]])#.*//' "$wf")"; then
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
elif [ "$(grep -cE '^ +reports-dir: evidence-reports$' <<<"$code")" -ne 3 ]; then
  fail_case "$name" "the expect step and both tools steps do not all read the downloaded legs (#1406)"
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
