#!/usr/bin/env bash
#
# The per-language report-file contract of the CI `test` and `audit` evidence
# gates and of the `quality` gate's `lint` and `typecheck` legs, and the
# staging of one matrix leg's reports (issues #1211, #1249).
#
# vrg-validate writes each gate's machine-readable reports at the workspace
# root under fixed names. The release-time harvester (vrg-ci-evidence) refuses
# a required gate whose artifact carries no report file, so the names staged
# here must be the names the gate commands write, language by language:
#
#   language  gate       report files                  tools
#   python    test       coverage.xml junit.xml        pytest, coverage.py
#   python    audit      pip-audit.json licenses.json  pip-audit, pip-licenses
#   python    lint       quality-ruff.json             ruff
#   python    typecheck  quality-mypy.xml              mypy
#   rust      test       coverage.xml junit.xml        cargo-llvm-cov, cargo-nextest
#   rust      audit      cargo-deny.json               cargo-deny
#   rust      lint       quality-clippy.json           rustfmt, clippy
#   rust      typecheck  quality-cargo-check.json      cargo
#
# The Rust test gate writes junit.xml through cargo-nextest from
# vergil-tooling#4395 on (vergil-actions#1216); a release of vergil-tooling
# without it writes none, so a passing Rust test leg on such a pin fails here.
# The Rust lint and typecheck gates write quality-clippy.json and
# quality-cargo-check.json from vergil-tooling#4473 on; the same holds for
# them. cargo-deny.json, quality-clippy.json and quality-cargo-check.json hold
# JSON Lines (one object per line); they are staged as written, never parsed.
#
# `lint` and `typecheck` are the quality gate's per-language legs. The quality
# gate's common and custom transcripts (quality-common.log and
# quality-custom.log) belong to no leg's contract: ci-quality.yml stages them
# itself.
#
# This table is the single place vergil-actions records the contract. The
# producer side is vergil-tooling's lib/languages.py (PYTHON_REPORT_FILES and
# RUST_REPORT_FILES); keep the two in step. Deriving this table from
# vergil-tooling instead is vergil-tooling#4416.
#
# A fleet language with no entry here (today go, cpp and typescript) writes no
# report the harvester accepts yet. Failing its leg would turn every PR of
# every repo in that language red, so instead every mode emits a ::warning::
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
#            is never staged.
#   tools  — write the gate's tools JSON array to $GITHUB_OUTPUT as `tools`,
#            for the evidence.json the emit action writes.
#   expect — check that REPORTS_DIR (the quality evidence job's downloaded
#            legs) holds at least one non-empty, version-suffixed copy of every
#            lint and typecheck report the language's contract names, and fail
#            naming each one missing. The emit action skips a file pattern that
#            matches nothing, so this check is what makes the reports required
#            in the quality artifact. GATE is not used.
#
# Inputs (env): MODE, LANGUAGE, GATE; for stage also VERSION, GATE_OUTCOME and
# OUT_DIR (default ci-reports); for expect REPORTS_DIR, and no GATE. Sourced
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
    python/audit) printf '%s\n' pip-audit.json licenses.json ;;
    rust/audit) printf '%s\n' cargo-deny.json ;;
    python/lint) printf '%s\n' quality-ruff.json ;;
    rust/lint) printf '%s\n' quality-clippy.json ;;
    python/typecheck) printf '%s\n' quality-mypy.xml ;;
    rust/typecheck) printf '%s\n' quality-cargo-check.json ;;
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
  esac
}

# stage_reports <language> <gate> <version> <gate-outcome> <out-dir>
stage_reports() {
  local language="$1" gate_name="$2" version="$3" outcome="$4" out_dir="$5"
  local names name stem ext missing=() staged=0

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

# expect_reports <language> <dir> — every lint and typecheck report of the
# language's contract is in <dir> at least once, version-suffixed
# (<stem>-<version>.<ext>) and non-empty. Fails naming each missing one.
expect_reports() {
  local language="$1" dir="$2" gate_name names name stem ext found
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
    if ! tools="$(report_tools "${LANGUAGE:-}" "$GATE")"; then
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
