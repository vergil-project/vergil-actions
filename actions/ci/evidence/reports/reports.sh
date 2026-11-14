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
#   rust      test   coverage.xml junit.xml        cargo-llvm-cov
#   rust      audit  cargo-deny.json               cargo-deny
#
# This table is the single place vergil-actions records the contract. The
# producer side is vergil-tooling's lib/languages.py (PYTHON_REPORT_FILES,
# and the Rust report names of vergil-tooling#4394); keep the two in step. A
# language or gate with no entry here fails loudly: its gate writes no report
# the harvester would accept, so a green leg would only defer the failure to
# the release.
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

# report_files <language> <gate> — the gate's report file names, one per line.
# Fails, with an ::error::, for a language or gate with no entry.
report_files() {
  case "$1/$2" in
    python/test | rust/test) printf '%s\n' coverage.xml junit.xml ;;
    python/audit) printf '%s\n' pip-audit.json licenses.json ;;
    rust/audit) printf '%s\n' cargo-deny.json ;;
    */test | */audit)
      error "no '$2' report contract for language '$1': its gate writes no" \
        "report file the release-time evidence gate accepts. Add the language's" \
        "report files to actions/ci/evidence/reports/reports.sh once its gate" \
        "commands write them"
      return 1
      ;;
    *)
      error "unknown gate '$2' (expected 'test' or 'audit')"
      return 1
      ;;
  esac
}

# report_tools <language> <gate> — the gate's tools JSON array, on one line.
report_tools() {
  case "$1/$2" in
    python/test) printf '%s\n' '[{"name":"pytest"},{"name":"coverage.py"}]' ;;
    python/audit) printf '%s\n' '[{"name":"pip-audit"},{"name":"pip-licenses"}]' ;;
    rust/test) printf '%s\n' '[{"name":"cargo-llvm-cov"}]' ;;
    rust/audit) printf '%s\n' '[{"name":"cargo-deny"}]' ;;
    *)
      # report_files carries the one wording for an unknown language or gate.
      report_files "$1" "$2" >/dev/null
      ;;
  esac
}

# stage_reports <language> <gate> <version> <gate-outcome> <out-dir>
stage_reports() {
  local language="$1" gate_name="$2" version="$3" outcome="$4" out_dir="$5"
  local names name stem ext missing=() staged=0

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
    tools="$(report_tools "$LANGUAGE" "$GATE")"
    echo "tools=${tools}" >>"$GITHUB_OUTPUT"
    echo "tools: ${tools}"
    ;;
  *)
    error "unknown MODE '$MODE' (expected 'stage' or 'tools')"
    exit 1
    ;;
esac
