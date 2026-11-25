#!/usr/bin/env bash
#
# The per-language report-file contract of the CI `test` and `audit` evidence
# gates and of the `quality` gate's `lint` and `typecheck` legs, and the
# staging of one matrix leg's reports (issues #1211, #1249, #1260).
#
# vrg-validate writes each gate's machine-readable reports at the workspace
# root under fixed names. The release-time harvester (vrg-ci-evidence) refuses
# a required gate whose artifact carries no report file, so the names staged
# here must be the names the gate commands write, language by language:
#
#   language    gate       report files                  tools
#   python      test       coverage.xml junit.xml        pytest, coverage.py
#   python      audit      pip-audit.json licenses.json  pip-audit, pip-licenses
#   python      lint       quality-ruff.json             ruff
#   python      typecheck  quality-mypy.xml              mypy
#   rust        test       coverage.xml junit.xml        cargo-llvm-cov, cargo-nextest
#   rust        audit      cargo-deny.json               cargo-deny
#   rust        lint       quality-clippy.json           rustfmt, clippy
#   rust        typecheck  quality-cargo-check.json      cargo
#   typescript  test       coverage.xml junit.xml        vitest, @vitest/coverage-v8
#   typescript  audit      npm-audit.json licenses.json  npm audit, vrg-npm-license-gate
#   typescript  lint       quality-eslint.json           prettier, eslint
#   typescript  typecheck  quality-tsc.txt               tsc
#
# The Rust test gate writes junit.xml through cargo-nextest from
# vergil-tooling#4395 on (vergil-actions#1216); a release of vergil-tooling
# without it writes none, so a passing Rust test leg on such a pin fails here.
# The Rust lint and typecheck gates write quality-clippy.json and
# quality-cargo-check.json from vergil-tooling#4473 on; the same holds for
# them. cargo-deny.json, quality-clippy.json and quality-cargo-check.json hold
# JSON Lines (one object per line); they are staged as written, never parsed.
#
# The TypeScript gates write their reports from vergil-tooling#4508 on (epic
# vergil-project/.github#1174): Vitest's JUnit report and its Cobertura
# coverage (copied to coverage.xml), `npm audit --json`, ESLint's JSON
# formatter output and `tsc --diagnostics` output. Prettier runs first in the
# lint gate and writes no report. As for Rust, a passing TypeScript leg on a
# vergil-tooling release without them fails here. The TypeScript audit gate
# also writes licenses.json, vrg-npm-license-gate's license report, from
# vergil-tooling#4722 on (released in v2.1.327; epic
# vergil-project/.github#1339), so a passing TypeScript audit leg on an earlier
# release fails here on the missing licenses.json.
#
# `lint` and `typecheck` are the quality gate's per-language legs. The quality
# gate's common and custom transcripts (quality-common.log and
# quality-custom.log) belong to no leg's contract: ci-quality.yml stages them
# itself.
#
# This table is the single place vergil-actions records the contract. The
# producer side is vergil-tooling's lib/languages.py (PYTHON_REPORT_FILES,
# RUST_REPORT_FILES and TYPESCRIPT_REPORT_FILES); keep the two in step.
# Deriving this table from vergil-tooling instead is vergil-tooling#4416.
#
# A fleet language with no entry here (today go and cpp) writes no report the
# harvester accepts yet. Failing its leg would turn every PR of every repo in
# that language red, so instead every mode emits a ::warning::
# naming the language and gate, stages nothing and gives an empty tools list;
# the release-time evidence gate still decides, and in enforcing mode it
# rejects an empty payload. An unknown language or gate, or any other bad
# input, fails.
#
# The quality gate also serves repositories with no fleet primary language (a
# shell or Claude plugin repository, or one that passes no language), whose
# lint and typecheck legs write no report. For the `lint` and `typecheck`
# gates, and in expect mode, such a language (or an empty one) is not a bad
# input: a ::notice:: says it has no report contract, nothing is staged, the
# tools list is empty, and the quality evidence carries the common and custom
# transcripts alone.
#
# Modes (env MODE):
#
#   stage  — copy the leg's report files into OUT_DIR as version-suffixed
#            basenames (<stem>-<VERSION>.<ext>), so each version's reports stay
#            distinct once the evidence job flattens them by basename (#836).
#            When the gate step succeeded (GATE_OUTCOME=success), every report
#            the table names must exist and be non-empty, or the step fails
#            naming each missing one. When it did not succeed, the leg has
#            already failed: the reports that exist are staged for diagnosis
#            and the missing ones are only noted. An empty or placeholder file
#            is never staged. The one exception is a gate vrg-validate skipped
#            because the repository is not bootstrapped yet (see below).
#   tools  — write the gate's tools JSON array to $GITHUB_OUTPUT as `tools`,
#            for the evidence.json the emit action writes. With REPORTS_DIR
#            (the evidence job's downloaded legs), a gate whose legs were all
#            skipped as not bootstrapped lists no tools, since none ran
#            (#1406): the skip records decide it, checked as expect mode
#            checks them.
#   expect — check that REPORTS_DIR (the quality evidence job's downloaded
#            legs) holds at least one non-empty, version-suffixed copy of every
#            lint and typecheck report the language's contract names, and fail
#            naming each one missing. The emit action skips a file pattern that
#            matches nothing, so this check is what makes the reports required
#            in the quality artifact. GATE is not used.
#
# A repository not bootstrapped yet (a freshly initialised one, with none of
# its language's manifests and no sources) has its language stages skipped by
# vrg-validate, loudly, each recorded `warn` in .vergil/vrg-validate-last.json
# (vergil-tooling#4384) with a `skip` giving the reason, the language and the
# missing manifests (vergil-tooling#5034, released in v2.1.342), and the gate
# exits 0 having written no report (#1294). Stage mode accepts such a leg only
# when the gate wrote none of its reports and all of these hold: the record is
# of the checked-out commit, the run exited 0, and every stage it ran is
# `warn`, the gate's among them, and carries a not-bootstrapped `skip` of the
# leg's language. The record decides: vergil-tooling's manifest and source
# tests are not repeated here, and a `warn` stage with no `skip` (a record of
# an earlier vergil-tooling release among them) is not a skip. It then prints a
# ::notice:: naming the leg and the reason, stages no report, and writes the
# leg's skip record, <gate>-not-bootstrapped-<version>.json (for a quality leg
# quality-<gate>-not-bootstrapped-<version>.json): a JSON object with
# skipped: true, reason "not-bootstrapped", the gate, language, version, head
# and the missing manifests, as the record gives them for the gate's stage.
# When any condition fails, each failing one is an
# ::error:: and the leg fails on its missing reports as before. The skip
# record is the gate's evidence of the skip: it reaches the evidence artifact
# with the leg's files, so the release-time harvester finds the skip recorded
# rather than an empty payload. Expect mode accepts a quality gate with no
# reports only when the legs' skip records for it are there, and fails on a
# skip record of another language or gate, or one found beside a report of
# the same gate. Tools mode, given REPORTS_DIR, reads the same skip records
# the same way and lists no tools for a gate whose legs were skipped, with a
# ::notice:: naming them, so the gate's evidence.json names no tool that never
# ran (#1406).
#
# Inputs (env): MODE, LANGUAGE, GATE; for stage also VERSION, GATE_OUTCOME and
# OUT_DIR (default ci-reports); for tools, optionally REPORTS_DIR; for expect
# REPORTS_DIR, and no GATE. Sourced
# (by tests/reports.test.sh), it defines the functions and runs nothing.
set -euo pipefail

error() {
  echo "::error::ci/evidence/reports: $*" >&2
}

# The fleet's primary languages, the ones the reusable CI workflows serve.
# Any other language name is a bad input, except for the quality gate's legs.
KNOWN_LANGUAGES="python rust go cpp typescript"

# The gates of the table. `lint` and `typecheck` are the quality gate's legs.
KNOWN_GATES="test audit lint typecheck"

# QUALITY_GATES — the gates expect mode checks, in order.
QUALITY_GATES="lint typecheck"

# is_known_language <language> — succeeds for a fleet primary language.
is_known_language() {
  case " ${KNOWN_LANGUAGES} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_quality_gate <gate> — succeeds for a quality gate leg, which also serves
# repositories with no fleet primary language.
is_quality_gate() {
  case " ${QUALITY_GATES} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# check_inputs <language> <gate> — fails, with an ::error::, for an unknown
# gate, or for an unknown language on a gate other than lint and typecheck.
check_inputs() {
  case " ${KNOWN_GATES} " in
    *" $2 "*) ;;
    *)
      error "unknown gate '$2' (expected one of: ${KNOWN_GATES})"
      return 1
      ;;
  esac
  if is_quality_gate "$2" || is_known_language "$1"; then
    return 0
  fi
  error "unknown language '$1' (expected one of: ${KNOWN_LANGUAGES})"
  return 1
}

# has_contract <language> <gate> — succeeds when the table has an entry.
has_contract() {
  case "$1/$2" in
    python/test | python/audit | python/lint | python/typecheck) return 0 ;;
    rust/test | rust/audit | rust/lint | rust/typecheck) return 0 ;;
    typescript/test | typescript/audit | typescript/lint | typescript/typecheck)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# warn_no_contract <language> <gate> <what> — the ::warning:: for a known
# language with no entry. On stderr, so tools mode's captured output holds
# only the JSON.
warn_no_contract() {
  echo "::warning::ci/evidence/reports: the $1 $2 gate's reports are not" \
    "produced yet (no '$2' report contract for language '$1'), so $3. The" \
    "release-time CI evidence gate decides; in enforcing mode it rejects an" \
    "empty payload. Add the language's report files to" \
    "actions/ci/evidence/reports/reports.sh once its gate commands write them" >&2
}

# note_no_language <language> <gate> <what> — the ::notice:: for a quality
# gate leg of a repository with no fleet primary language. On stderr, like
# warn_no_contract.
note_no_language() {
  echo "::notice::ci/evidence/reports: language '$1' is not a fleet primary" \
    "language (${KNOWN_LANGUAGES}), so its $2 leg has no report contract" \
    "and $3; the quality evidence carries the common and custom transcripts" >&2
}

# no_contract <language> <gate> <what> — for an input with no entry: the
# warning for a fleet primary language, the notice for any other.
no_contract() {
  if is_known_language "$1"; then
    warn_no_contract "$1" "$2" "$3"
  else
    note_no_language "$1" "$2" "$3"
  fi
}

# report_files <language> <gate> — the gate's report file names, one per line,
# for an entry in the table. Callers check the inputs and the entry first.
report_files() {
  case "$1/$2" in
    python/test) printf '%s\n' coverage.xml junit.xml ;;
    rust/test) printf '%s\n' coverage.xml junit.xml ;;
    typescript/test) printf '%s\n' coverage.xml junit.xml ;;
    python/audit) printf '%s\n' pip-audit.json licenses.json ;;
    rust/audit) printf '%s\n' cargo-deny.json ;;
    typescript/audit) printf '%s\n' npm-audit.json licenses.json ;;
    python/lint) printf '%s\n' quality-ruff.json ;;
    rust/lint) printf '%s\n' quality-clippy.json ;;
    typescript/lint) printf '%s\n' quality-eslint.json ;;
    python/typecheck) printf '%s\n' quality-mypy.xml ;;
    rust/typecheck) printf '%s\n' quality-cargo-check.json ;;
    typescript/typecheck) printf '%s\n' quality-tsc.txt ;;
    *)
      error "internal: no report files for '$1/$2'"
      return 1
      ;;
  esac
}

# report_tools <language> <gate> — the gate's tools JSON array, on one line.
# Fails for a bad input (check_inputs); an input with no entry warns (or, for
# a quality gate leg of a non-primary language, notes) and gives an empty
# array.
report_tools() {
  check_inputs "$1" "$2" || return 1
  if ! has_contract "$1" "$2"; then
    no_contract "$1" "$2" "its evidence lists no tools"
    printf '%s\n' '[]'
    return 0
  fi
  case "$1/$2" in
    python/test) printf '%s\n' '[{"name":"pytest"},{"name":"coverage.py"}]' ;;
    python/audit) printf '%s\n' '[{"name":"pip-audit"},{"name":"pip-licenses"}]' ;;
    python/lint) printf '%s\n' '[{"name":"ruff"}]' ;;
    python/typecheck) printf '%s\n' '[{"name":"mypy"}]' ;;
    rust/test) printf '%s\n' '[{"name":"cargo-llvm-cov"},{"name":"cargo-nextest"}]' ;;
    rust/audit) printf '%s\n' '[{"name":"cargo-deny"}]' ;;
    rust/lint) printf '%s\n' '[{"name":"rustfmt"},{"name":"clippy"}]' ;;
    rust/typecheck) printf '%s\n' '[{"name":"cargo"}]' ;;
    typescript/test) printf '%s\n' '[{"name":"vitest"},{"name":"@vitest/coverage-v8"}]' ;;
    typescript/audit) printf '%s\n' '[{"name":"npm audit"},{"name":"vrg-npm-license-gate"}]' ;;
    typescript/lint) printf '%s\n' '[{"name":"prettier"},{"name":"eslint"}]' ;;
    typescript/typecheck) printf '%s\n' '[{"name":"tsc"}]' ;;
    *)
      # A contract with no tools entry would ship an empty tools list
      # silently; has_contract and this table must change together.
      error "internal: no tools for '$1/$2'"
      return 1
      ;;
  esac
}

# --- the not-bootstrapped skip (#1294) ----------------------------------------

# The record vrg-validate writes at the repository root after every run
# (vergil-tooling's lib/validate_record.py).
VALIDATE_RECORD=".vergil/vrg-validate-last.json"

# The reason a skip record carries, and the reason vrg-validate's record gives
# a stage it skipped because the repository is not bootstrapped yet.
SKIP_REASON="not-bootstrapped"

# SKIP_DEF — a jq definition, `is_skip`: a record stage (the input) carries
# the skip vrg-validate gives a stage it skipped as not bootstrapped, with
# reason $reason, language $language and a non-empty list of missing
# manifests (vergil-tooling#5034). $reason and $language are jq variables,
# bound by each jq call's --arg, never shell expansions.
# shellcheck disable=SC2016
SKIP_DEF='def is_skip: (.skip | type) == "object" and .skip.reason == $reason
  and .skip.language == $language
  and (.skip.missing_manifests | type) == "array"
  and (.skip.missing_manifests | length) > 0
  and all(.skip.missing_manifests[]; type == "string" and length > 0);'

# skip_marker_name <gate> <version> — the basename of a leg's skip record.
# A quality leg's carries the quality- prefix, so the quality evidence job's
# emit pattern (evidence-reports/quality-*) takes it with the reports.
skip_marker_name() {
  if is_quality_gate "$1"; then
    printf 'quality-%s-%s-%s.json\n' "$1" "$SKIP_REASON" "$2"
  else
    printf '%s-%s-%s.json\n' "$1" "$SKIP_REASON" "$2"
  fi
}

# need_jq — fails, with an ::error::, when jq is not on PATH.
need_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    error "jq is not on PATH; it is needed to read $1"
    return 1
  fi
}

# record_gate_status <gate> — print the status the vrg-validate record gives
# the gate's stage, or nothing when the record is absent or has no such stage.
# Fails, with an ::error::, on a record it cannot read.
record_gate_status() {
  [ -f "$VALIDATE_RECORD" ] || return 0
  need_jq "the vrg-validate record ${VALIDATE_RECORD}" || return 1
  if ! jq -r --arg gate "$1" \
    '[.stages[] | select(.name == $gate) | .status] | join(",")' \
    "$VALIDATE_RECORD"; then
    error "cannot read the vrg-validate record ${VALIDATE_RECORD}"
    return 1
  fi
}

# check_not_bootstrapped <language> <gate> — succeed, printing the missing
# manifests, only when the gate's vrg-validate run really skipped it because
# the repository is not bootstrapped yet. vrg-validate records why it skipped
# each such stage as the stage's `skip` (vergil-tooling#5034, released in
# v2.1.342), so the record alone decides: the manifest and source tests are
# vergil-tooling's and are not repeated here. Every condition must hold, and
# each one that does not fails with an ::error:: naming it:
#
#   - the record's head is the commit checked out (git rev-parse HEAD);
#   - the run exited 0;
#   - every stage of the run is `warn` (no stage really ran);
#   - every stage carries a `skip` with reason "not-bootstrapped", the leg's
#     language and a non-empty list of missing manifests, as vrg-validate
#     gives each stage of a run on a repository not bootstrapped yet. A
#     `warn` stage with no `skip` is some other warning, or a record written
#     by a vergil-tooling release before #5034, and is never taken for one.
#
# The caller has already found the gate's stage recorded `warn`. The missing
# manifests printed, comma-separated, are the gate's stage's.
check_not_bootstrapped() {
  local language="$1" gate_name="$2" head record_head exit_code ran unexplained
  local foreign manifests bad=0

  if ! head="$(git rev-parse HEAD)"; then
    error "git cannot resolve HEAD, so the not-bootstrapped skip cannot be checked"
    return 1
  fi
  if ! record_head="$(jq -r '.head' "$VALIDATE_RECORD")" ||
    ! exit_code="$(jq -r '.exit_code' "$VALIDATE_RECORD")" ||
    ! ran="$(jq -r '[.stages[] | select(.status != "warn") |
        "\(.name) (\(.status))"] | join(", ")' "$VALIDATE_RECORD")" ||
    ! unexplained="$(jq -r '[.stages[] | select(.status == "warn" and
        (has("skip") | not)) | .name] | join(", ")' "$VALIDATE_RECORD")" ||
    ! foreign="$(jq -r --arg reason "$SKIP_REASON" --arg language "$language" \
      "${SKIP_DEF}"' [.stages[] | select(.status == "warn" and has("skip")) |
        select(is_skip | not) | "\(.name) (\(.skip | tojson))"] |
        join(", ")' "$VALIDATE_RECORD")" ||
    ! manifests="$(jq -r --arg reason "$SKIP_REASON" --arg language "$language" \
      --arg gate "$gate_name" "${SKIP_DEF}"' [.stages[] |
        select(.name == $gate and is_skip) | .skip.missing_manifests |
        join(", ")] | first // ""' "$VALIDATE_RECORD")"; then
    error "cannot read the vrg-validate record ${VALIDATE_RECORD}"
    return 1
  fi
  if [ "$record_head" != "$head" ]; then
    error "the vrg-validate record ${VALIDATE_RECORD} is of commit" \
      "${record_head}, not the checked-out ${head}, so it does not show this" \
      "${gate_name} gate skipped"
    bad=1
  fi
  if [ "$exit_code" != "0" ]; then
    error "the vrg-validate record ${VALIDATE_RECORD} shows the run exited" \
      "${exit_code}, so it does not show the ${gate_name} gate skipped"
    bad=1
  fi
  if [ -n "$ran" ]; then
    error "the vrg-validate record ${VALIDATE_RECORD} shows stages that ran" \
      "(${ran}), so the ${gate_name} gate was not skipped as not bootstrapped"
    bad=1
  fi
  if [ -n "$unexplained" ]; then
    error "the vrg-validate record ${VALIDATE_RECORD} records stages warn with" \
      "no skip (${unexplained}), so it does not show the ${gate_name} gate" \
      "skipped as not bootstrapped; vergil-tooling records the skip from" \
      "v2.1.342 on (vergil-tooling#5034)"
    bad=1
  fi
  if [ -n "$foreign" ]; then
    error "the vrg-validate record ${VALIDATE_RECORD} records stages skipped" \
      "other than as a ${language} repo not bootstrapped (${foreign}), so it" \
      "does not show the ${gate_name} gate skipped as not bootstrapped"
    bad=1
  fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$manifests" ]; then
    error "internal: the vrg-validate record ${VALIDATE_RECORD} gives the" \
      "${gate_name} stage no missing manifests"
    return 1
  fi
  echo "$manifests"
}

# stage_skip <language> <gate> <version> <out-dir> <manifests> — the notice for
# a leg skipped as not bootstrapped, and its skip record in out-dir, the only
# file staged for it.
stage_skip() {
  local language="$1" gate_name="$2" version="$3" out_dir="$4" manifests="$5"
  local marker head
  marker="${out_dir}/$(skip_marker_name "$gate_name" "$version")"
  head="$(git rev-parse HEAD)" || return 1
  if ! jq -n --arg gate "$gate_name" --arg language "$language" \
    --arg version "$version" --arg reason "$SKIP_REASON" --arg head "$head" \
    --arg manifests "$manifests" \
    '{gate: $gate, language: $language, version: $version, skipped: true,
      reason: $reason, head: $head,
      missing_manifests: ($manifests | split(", "))}' >"$marker"; then
    error "cannot write the skip record ${marker}"
    return 1
  fi
  echo "::notice title=ci/evidence/reports::the ${language} ${gate_name}" \
    "leg ${version} wrote no reports: vrg-validate skipped the gate because" \
    "the repo is not bootstrapped yet (no ${manifests}, and no ${language}" \
    "sources). No report is staged; the skip is recorded in ${marker}"
}

# stage_reports <language> <gate> <version> <gate-outcome> <out-dir>
stage_reports() {
  local language="$1" gate_name="$2" version="$3" outcome="$4" out_dir="$5"
  local names name stem ext missing=() staged=0 status manifests

  check_inputs "$language" "$gate_name" || return 1
  if [ -z "$version" ]; then
    error "VERSION is empty; pass the matrix leg's version"
    return 1
  fi
  case "$version" in
    */* | *..*)
      error "VERSION '$version' is not a single path component"
      return 1
      ;;
  esac
  if ! has_contract "$language" "$gate_name"; then
    no_contract "$language" "$gate_name" "none are staged"
    return 0
  fi
  if ! names="$(report_files "$language" "$gate_name")"; then
    return 1
  fi

  mkdir -p "$out_dir"
  while IFS= read -r name; do
    if [ ! -f "$name" ] || [ ! -s "$name" ]; then
      missing+=("$name")
      continue
    fi
    stem="${name%.*}"
    ext="${name##*.}"
    cp "$name" "${out_dir}/${stem}-${version}.${ext}"
    echo "staged ${name} as ${out_dir}/${stem}-${version}.${ext}"
    staged=$((staged + 1))
  done <<<"$names"

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "$outcome" = "success" ]; then
    # A gate that wrote none of its reports may have been skipped by
    # vrg-validate as not bootstrapped (#1294): its stage is then recorded
    # `warn`. The skip is accepted only when check_not_bootstrapped proves it;
    # when it does not, its errors say why, and the gate fails below on its
    # missing reports, as any gate that wrote no report does.
    if [ "$staged" -eq 0 ]; then
      status="$(record_gate_status "$gate_name")" || return 1
      if [ "$status" = "warn" ] &&
        manifests="$(check_not_bootstrapped "$language" "$gate_name")"; then
        stage_skip "$language" "$gate_name" "$version" "$out_dir" \
          "$manifests" || return 1
        return 0
      fi
    fi
    for name in "${missing[@]}"; do
      error "the ${language} ${gate_name} gate passed but wrote no ${name}" \
        "(missing or empty at the workspace root); the release-time evidence" \
        "gate needs every report"
    done
    return 1
  fi
  for name in "${missing[@]}"; do
    echo "::notice::ci/evidence/reports: ${name} not staged: the ${gate_name}" \
      "gate step did not succeed (outcome '${outcome}') and left it missing or" \
      "empty"
  done
  echo "staged ${staged} of $(wc -l <<<"$names") ${gate_name} reports"
}

# expect_skip <language> <gate> <dir> <names> — print the skip records <dir>
# holds for the gate's legs, comma-separated, or nothing when it holds none.
# A stage step writes one only for a leg it proved was skipped as not
# bootstrapped (#1294), so the gate's reports are then not expected. Fails,
# with an ::error::, for a skip record that is not one of this language and
# gate, or when <dir> also holds a report of the gate (<names>, one per line):
# every leg of a gate sees the same checkout, so all skip or none do.
expect_skip() {
  local language="$1" gate_name="$2" dir="$3" names="$4" pattern marker
  local markers=() name stem ext found bad=0

  pattern="$(skip_marker_name "$gate_name" '*')"
  while IFS= read -r -d '' marker; do
    markers+=("$marker")
  done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)
  [ "${#markers[@]}" -gt 0 ] || return 0

  need_jq "the skip records in ${dir}" || return 1
  for marker in "${markers[@]}"; do
    if ! jq -e --arg gate "$gate_name" --arg language "$language" \
      --arg reason "$SKIP_REASON" \
      '.skipped == true and .reason == $reason and .gate == $gate and
        .language == $language' "$marker" >/dev/null 2>&1; then
      error "${marker} is not a ${language} ${gate_name} skip record" \
        "(skipped: true, reason: ${SKIP_REASON})"
      bad=1
    fi
  done
  while IFS= read -r name; do
    stem="${name%.*}"
    ext="${name##*.}"
    found="$(find "$dir" -maxdepth 1 -type f -name "${stem}-*.${ext}" -print -quit)"
    if [ -n "$found" ]; then
      error "${dir} holds both a ${language} ${gate_name} skip record and the" \
        "report ${found}: a gate's legs are skipped as not bootstrapped all" \
        "together or not at all"
      bad=1
    fi
  done <<<"$names"
  [ "$bad" -eq 0 ] || return 1
  local IFS=,
  echo "${markers[*]##*/}"
}

# skipped_tools <language> <gate> <dir> — the gate's tools JSON array for the
# evidence job whose downloaded legs are in <dir>: `[]`, with a ::notice::,
# when the legs were skipped as not bootstrapped (expect_skip), and
# report_tools' array otherwise. An input with no contract is report_tools'
# (its legs stage nothing, so <dir> may not exist). Fails for a bad input, a
# <dir> that is not a directory, or a skip record expect_skip refuses.
skipped_tools() {
  local language="$1" gate_name="$2" dir="$3" names skipped
  check_inputs "$language" "$gate_name" || return 1
  if ! has_contract "$language" "$gate_name"; then
    report_tools "$language" "$gate_name"
    return
  fi
  # Every passing leg of a gate with a contract uploads its reports or its
  # skip record, so the evidence job's download directory exists.
  if [ ! -d "$dir" ]; then
    error "REPORTS_DIR '${dir}' is not a directory"
    return 1
  fi
  names="$(report_files "$language" "$gate_name")" || return 1
  skipped="$(expect_skip "$language" "$gate_name" "$dir" "$names")" || return 1
  if [ -n "$skipped" ]; then
    echo "::notice title=ci/evidence/reports::the ${language} ${gate_name}" \
      "legs were skipped as not bootstrapped (${skipped}), so the" \
      "${gate_name} evidence lists none of their tools" >&2
    printf '%s\n' '[]'
    return 0
  fi
  report_tools "$language" "$gate_name"
}

# expect_reports <language> <dir> — every lint and typecheck report of the
# language's contract is in <dir> at least once, version-suffixed
# (<stem>-<version>.<ext>) and non-empty, unless the gate's legs were all
# skipped as not bootstrapped (expect_skip). Fails naming each missing one.
expect_reports() {
  local language="$1" dir="$2" gate_name names name stem ext found skipped
  local missing=()

  if [ -z "$dir" ]; then
    error "REPORTS_DIR is empty; pass the directory holding the legs' reports"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    error "REPORTS_DIR '${dir}' is not a directory"
    return 1
  fi
  for gate_name in ${QUALITY_GATES}; do
    if ! has_contract "$language" "$gate_name"; then
      no_contract "$language" "$gate_name" "no report is expected"
      continue
    fi
    if ! names="$(report_files "$language" "$gate_name")"; then
      return 1
    fi
    if ! skipped="$(expect_skip "$language" "$gate_name" "$dir" "$names")"; then
      return 1
    fi
    if [ -n "$skipped" ]; then
      echo "::notice title=ci/evidence/reports::the ${language} ${gate_name}" \
        "legs were skipped as not bootstrapped (${skipped}), so no" \
        "${gate_name} report is expected"
      continue
    fi
    while IFS= read -r name; do
      stem="${name%.*}"
      ext="${name##*.}"
      found="$(find "$dir" -maxdepth 1 -type f -name "${stem}-*.${ext}" \
        -size +0 -print -quit)"
      if [ -z "$found" ]; then
        missing+=("${gate_name} ${name}")
      else
        echo "found the ${language} ${gate_name} report ${name} as ${found}"
      fi
    done <<<"$names"
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  for name in "${missing[@]}"; do
    error "no ${language} ${name%% *} leg staged its ${name#* }: ${dir} holds" \
      "no non-empty ${name#* } (as <stem>-<version>.<ext>); the release-time" \
      "evidence gate needs every quality report"
  done
  return 1
}

# Sourced: define the functions, run nothing.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

if [ -z "${MODE:-}" ]; then
  error "MODE is empty"
  exit 1
fi
# Expect mode takes no GATE. LANGUAGE may be empty only where a repository
# with no language is served: the lint and typecheck legs, and expect mode.
if [ "$MODE" != "expect" ] && [ -z "${GATE:-}" ]; then
  error "GATE is empty"
  exit 1
fi
if [ -z "${LANGUAGE:-}" ] && [ "$MODE" != "expect" ] &&
  ! is_quality_gate "$GATE"; then
  error "LANGUAGE is empty"
  exit 1
fi

case "$MODE" in
  stage)
    stage_reports "${LANGUAGE:-}" "$GATE" "${VERSION:-}" "${GATE_OUTCOME:-}" \
      "${OUT_DIR:-ci-reports}"
    ;;
  tools)
    if [ -z "${GITHUB_OUTPUT:-}" ]; then
      error "GITHUB_OUTPUT is not set"
      exit 1
    fi
    # With the evidence job's downloaded legs, a gate whose legs were
    # skipped as not bootstrapped lists no tools (#1406).
    if [ -n "${REPORTS_DIR:-}" ]; then
      if ! tools="$(skipped_tools "${LANGUAGE:-}" "$GATE" "$REPORTS_DIR")"; then
        exit 1
      fi
    elif ! tools="$(report_tools "${LANGUAGE:-}" "$GATE")"; then
      exit 1
    fi
    echo "tools=${tools}" >>"$GITHUB_OUTPUT"
    echo "tools: ${tools}"
    ;;
  expect)
    expect_reports "${LANGUAGE:-}" "${REPORTS_DIR:-}"
    ;;
  *)
    error "unknown MODE '$MODE' (expected 'stage', 'tools' or 'expect')"
    exit 1
    ;;
esac
