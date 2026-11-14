#!/usr/bin/env bash
#
# Behavioural test for sweep.sh — the branch-sweep action's reporting core
# (issue #952).
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash sweep.test.sh`.
#
# Each case puts a stub `vrg-branch-sweep` on PATH that prints a canned report
# in the exact shape vergil-tooling's branch_sweep.format_outcomes/summarize
# produce, then runs sweep.sh and asserts its exit code, job summary and
# workflow-command annotations.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep_sh="${here}/../sweep.sh"

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

# run_sweep <report-text> <stub-exit-code>
# Sets globals: rc, out (stdout+stderr), summary (job summary contents), args.
run_sweep() {
  local report="$1" stub_rc="$2" dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/bin"
  printf '%s\n' "${report}" >"${dir}/report.txt"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"%s/args.txt"\ncat "%s/report.txt"\nexit %s\n' \
    "${dir}" "${dir}" "${stub_rc}" >"${dir}/bin/vrg-branch-sweep"
  chmod +x "${dir}/bin/vrg-branch-sweep"
  : >"${dir}/summary.md"

  set +e
  out="$(PATH="${dir}/bin:${PATH}" REPO=acme/widgets \
    GITHUB_STEP_SUMMARY="${dir}/summary.md" GITHUB_SERVER_URL=https://github.com \
    bash "${sweep_sh}" 2>&1)"
  rc=$?
  set -e
  summary="$(cat "${dir}/summary.md")"
  args="$(cat "${dir}/args.txt" 2>/dev/null || true)"
  rm -rf "${dir}"
}

# expect <name> <condition-description> <test-command...>
check() {
  local name="$1" what="$2"
  shift 2
  if ! "$@"; then
    fail_case "${name}" "${what}; rc=${rc}; output: ${out}; summary: ${summary}"
    return 1
  fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac }
lacks() { ! contains "$1" "$2"; }

mixed_report='Sweeping finished branches in acme/widgets (apply)
develop                 -       -       kept (default branch)
feature/12-done         #40     MERGED  deleted (PR #40 merged)
feature/13-wip          #41     OPEN    kept (open PR #41)
feature/14-new          -       -       kept (no PR)
feature/15-a|b<x>       #42     MERGED  deleted (PR #42 merged)
release/2.0.55          #31     CLOSED  deleted (PR #31 closed)

acme/widgets: 6 branches, 3 deleted, 3 kept, 0 errors'

case_mixed() {
  local name="mixed-deletions"
  run_sweep "${mixed_report}" 0
  check "${name}" "expected exit 0" [ "${rc}" -eq 0 ] || return
  check "${name}" "sweep must run with --apply on the repo" \
    [ "${args}" = "--repo acme/widgets --apply" ] || return
  check "${name}" "merged warning block" contains "${summary}" \
    '> **2 branch(es) of merged PRs were still on origin.**' || return
  check "${name}" "merged row" contains "${summary}" \
    '| <code>feature/12-done</code> | [#40](https://github.com/acme/widgets/pull/40) |' || return
  check "${name}" "branch name is escaped" contains "${summary}" \
    '<code>feature/15-a&#124;b&lt;x&gt;</code>' || return
  check "${name}" "closed section" contains "${summary}" \
    '### Deleted: PR closed without merging' || return
  check "${name}" "closed row" contains "${summary}" '<code>release/2.0.55</code>' || return
  check "${name}" "kept branches are not listed as deletions" lacks "${summary}" \
    '<code>feature/13-wip</code>' || return
  check "${name}" "annotation per merged branch" contains "${out}" \
    '::warning title=Merged-PR branch left on origin::feature/12-done (PR #40)' || return
  check "${name}" "no annotation for closed branch" lacks "${out}" \
    '::warning title=Merged-PR branch left on origin::release/2.0.55' || return
  pass_case "${name}"
}

case_nothing() {
  local name="nothing-to-delete"
  run_sweep 'Sweeping finished branches in acme/widgets (apply)
develop  -       -       kept (default branch)

acme/widgets: 1 branches, 0 deleted, 1 kept, 0 errors' 0
  check "${name}" "expected exit 0" [ "${rc}" -eq 0 ] || return
  check "${name}" "clean message" contains "${summary}" \
    'No finished branches were left on origin.' || return
  check "${name}" "no merged warning" lacks "${summary}" '[!WARNING]' || return
  check "${name}" "no annotation" lacks "${out}" '::warning' || return
  pass_case "${name}"
}

case_closed_only() {
  local name="closed-only-no-warning"
  run_sweep 'Sweeping finished branches in acme/widgets (apply)
release/2.0.55  #31     CLOSED  deleted (PR #31 closed)

acme/widgets: 1 branches, 1 deleted, 0 kept, 0 errors' 0
  check "${name}" "expected exit 0" [ "${rc}" -eq 0 ] || return
  check "${name}" "no merged warning" lacks "${summary}" '[!WARNING]' || return
  check "${name}" "closed row" contains "${summary}" '<code>release/2.0.55</code>' || return
  pass_case "${name}"
}

case_branch_error() {
  local name="branch-error-fails"
  run_sweep 'Sweeping finished branches in acme/widgets (apply)
feature/12-done  #40     MERGED  deleted (PR #40 merged)
feature/16-bad   #43     MERGED  error (delete failed: HTTP 422)

acme/widgets: 2 branches, 1 deleted, 0 kept, 1 errors
vrg-branch-sweep: 1 branch(es) failed: feature/16-bad' 1
  check "${name}" "expected exit 1" [ "${rc}" -eq 1 ] || return
  check "${name}" "errors section" contains "${summary}" '### Errors' || return
  check "${name}" "error row" contains "${summary}" '<code>feature/16-bad</code>' || return
  check "${name}" "exit noted" contains "${summary}" 'exited 1' || return
  check "${name}" "deleted branch still reported" contains "${summary}" \
    '<code>feature/12-done</code>' || return
  pass_case "${name}"
}

case_listing_failure() {
  local name="listing-failure-fails"
  run_sweep 'Sweeping finished branches in acme/widgets (apply)
vrg-branch-sweep: cannot list branches of acme/widgets: HTTP 403' 1
  check "${name}" "expected exit 1" [ "${rc}" -eq 1 ] || return
  check "${name}" "exit noted" contains "${summary}" 'exited 1' || return
  check "${name}" "raw output in summary" contains "${summary}" 'cannot list branches' || return
  check "${name}" "no clean message" lacks "${summary}" 'No finished branches' || return
  pass_case "${name}"
}

case_format_drift_count() {
  local name="format-drift-count-mismatch-fails"
  # The summary says 2 deleted but only one line parses as a deletion.
  run_sweep 'Sweeping finished branches in acme/widgets (apply)
feature/12-done  #40     MERGED  deleted (PR #40 merged)
feature/17-x  PR-44  MERGED  deleted (PR #44 merged)

acme/widgets: 2 branches, 2 deleted, 0 kept, 0 errors' 0
  check "${name}" "expected exit 1" [ "${rc}" -eq 1 ] || return
  check "${name}" "mismatch annotation" contains "${out}" \
    '::error title=Branch sweep report mismatch::' || return
  pass_case "${name}"
}

case_format_drift_no_summary() {
  local name="format-drift-no-summary-fails"
  run_sweep 'Sweeping finished branches in acme/widgets (apply)
something unexpected' 0
  check "${name}" "expected exit 1" [ "${rc}" -eq 1 ] || return
  check "${name}" "mismatch annotation" contains "${out}" 'printed no summary line' || return
  pass_case "${name}"
}

case_missing_repo() {
  local name="missing-repo-fails-closed" rc_local
  set +e
  env -u REPO GITHUB_STEP_SUMMARY=/dev/null bash "${sweep_sh}" >/dev/null 2>&1
  rc_local=$?
  set -e
  if [ "${rc_local}" -eq 0 ]; then
    fail_case "${name}" "expected non-zero exit without REPO"
    return
  fi
  pass_case "${name}"
}

case_mixed
case_nothing
case_closed_only
case_branch_error
case_listing_failure
case_format_drift_count
case_format_drift_no_summary
case_missing_repo

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
