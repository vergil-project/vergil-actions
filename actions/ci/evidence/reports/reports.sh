#!/usr/bin/env bash
#
# The per-language report-file contract of the CI `test` and `audit` evidence
# gates, and the staging of one matrix leg's reports (issue #1211).
#
# vrg-validate writes each gate's machine-readable reports at the workspace
# root under fixed names. The release-time harvester (vrg-ci-evidence) refuses
# a required gate whose artifact carries no report file, so the names staged
# here must be the names the gate commands write, language by language:
#
#   language  gate   report files                  tools
#   python    test   coverage.xml junit.xml        pytest, coverage.py
#   python    audit  pip-audit.json licenses.json  pip-audit, pip-licenses
#   rust      test   coverage.xml junit.xml        cargo-llvm-cov, cargo-nextest
#   rust      audit  cargo-deny.json               cargo-deny
#
# The Rust test gate writes junit.xml through cargo-nextest from
# vergil-tooling#4395 on (vergil-actions#1216); a release of vergil-tooling
# without it writes none, so a passing Rust test leg on such a pin fails here.
# cargo-deny.json holds JSON Lines (one object per line); it is staged as
# written, never parsed.
#
# This table is the single place vergil-actions records the contract. The
# producer side is vergil-tooling's lib/languages.py (PYTHON_REPORT_FILES and
# RUST_REPORT_FILES); keep the two in step. Deriving this table from
# vergil-tooling instead is vergil-tooling#4416.
#
# A fleet language with no entry here (today go, cpp and typescript) writes no
# report the harvester accepts yet. Failing its leg would turn every PR of
# every repo in that language red, so instead both modes emit a ::warning::
# naming the language and gate, stage nothing and give an empty tools list;
# the release-time evidence gate still decides, and in enforcing mode it
# rejects the empty payload. An unknown language or gate, or any other bad
# input, fails.
#
# Modes (env MODE):
#
#   stage — copy the leg's report files into OUT_DIR as version-suffixed
#           basenames (<stem>-<VERSION>.<ext>), so each version's reports stay
#           distinct once the evidence job flattens them by basename (#836).
#           When the gate step succeeded (GATE_OUTCOME=success), every report
#           the table names must exist and be non-empty, or the step fails
#           naming each missing one. When it did not succeed, the leg has
#           already failed: the reports that exist are staged for diagnosis
#           and the missing ones are only noted. An empty or placeholder file
#           is never staged.
#   tools — write the gate's tools JSON array to $GITHUB_OUTPUT as `tools`,
#           for the evidence.json the emit action writes.
#
# Inputs (env): MODE, LANGUAGE, GATE; for stage also VERSION, GATE_OUTCOME and
# OUT_DIR (default ci-reports). Sourced (by tests/reports.test.sh), it defines
# the functions and runs nothing.
set -euo pipefail

error() {
  echo "::error::ci/evidence/reports: $*" >&2
}

# The fleet's primary languages, the ones the reusable CI workflows serve.
# Any other language name is a bad input.
KNOWN_LANGUAGES="python rust go cpp typescript"

# check_inputs <language> <gate> — fails, with an ::error::, for an unknown
# language or gate.
check_inputs() {
  case "$2" in
    test | audit) ;;
    *)
      error "unknown gate '$2' (expected 'test' or 'audit')"
      return 1
      ;;
  esac
  case " ${KNOWN_LANGUAGES} " in
    *" $1 "*) ;;
    *)
      error "unknown language '$1' (expected one of: ${KNOWN_LANGUAGES})"
      return 1
      ;;
  esac
}

# has_contract <language> <gate> — succeeds when the table has an entry.
has_contract() {
  case "$1/$2" in
    python/test | python/audit | rust/test | rust/audit) return 0 ;;
    *) return 1 ;;
  esac
}

# warn_no_contract <language> <gate> <what> — the ::warning:: for a known
# language with no entry. On stderr, so tools mode's captured output holds
# only the JSON.
warn_no_contract() {
  echo "::warning::ci/evidence/reports: the $1 $2 gate's reports are not" \
    "produced yet (no '$2' report contract for language '$1'), so $3. The" \
    "release-time CI evidence gate decides; in enforcing mode it rejects the" \
    "empty payload. Add the language's report files to" \
    "actions/ci/evidence/reports/reports.sh once its gate commands write them" >&2
}

# report_files <language> <gate> — the gate's report file names, one per line,
# for an entry in the table. Callers check the inputs and the entry first.
report_files() {
  case "$1/$2" in
    python/test) printf '%s\n' coverage.xml junit.xml ;;
    rust/test) printf '%s\n' coverage.xml junit.xml ;;
    python/audit) printf '%s\n' pip-audit.json licenses.json ;;
    rust/audit) printf '%s\n' cargo-deny.json ;;
    *)
      error "internal: no report files for '$1/$2'"
      return 1
      ;;
  esac
}

# report_tools <language> <gate> — the gate's tools JSON array, on one line.
# Fails for an unknown language or gate; a known language with no entry
# warns and gives an empty array.
report_tools() {
  check_inputs "$1" "$2" || return 1
  if ! has_contract "$1" "$2"; then
    warn_no_contract "$1" "$2" "its evidence lists no tools"
    printf '%s\n' '[]'
    return 0
  fi
  case "$1/$2" in
    python/test) printf '%s\n' '[{"name":"pytest"},{"name":"coverage.py"}]' ;;
    python/audit) printf '%s\n' '[{"name":"pip-audit"},{"name":"pip-licenses"}]' ;;
    rust/test) printf '%s\n' '[{"name":"cargo-llvm-cov"},{"name":"cargo-nextest"}]' ;;
    rust/audit) printf '%s\n' '[{"name":"cargo-deny"}]' ;;
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
    warn_no_contract "$language" "$gate_name" "none are staged"
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

# Sourced: define the functions, run nothing.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

for name in MODE LANGUAGE GATE; do
  if [ -z "${!name:-}" ]; then
    error "${name} is empty"
    exit 1
  fi
done

case "$MODE" in
  stage)
    stage_reports "$LANGUAGE" "$GATE" "${VERSION:-}" "${GATE_OUTCOME:-}" \
      "${OUT_DIR:-ci-reports}"
    ;;
  tools)
    if [ -z "${GITHUB_OUTPUT:-}" ]; then
      error "GITHUB_OUTPUT is not set"
      exit 1
    fi
    if ! tools="$(report_tools "$LANGUAGE" "$GATE")"; then
      exit 1
    fi
    echo "tools=${tools}" >>"$GITHUB_OUTPUT"
    echo "tools: ${tools}"
    ;;
  *)
    error "unknown MODE '$MODE' (expected 'stage' or 'tools')"
    exit 1
    ;;
esac
