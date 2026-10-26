#!/usr/bin/env bash
#
# Run a Trivy `fs` or `image` vulnerability scan and tell its three outcomes
# apart (issue #1079, vergil-containers#721):
#
#   passed   — the scan wrote its report and exited 0.
#   findings — the scan wrote its report and exited non-zero: Trivy found
#              vulnerabilities at the requested severity (after .trivyignore).
#              Not retried; a rerun would find the same thing.
#   error    — the scan wrote no report. Trivy stopped before it could report
#              (a dropped image-layer download, a failed vulnerability-DB
#              download, …). Retried with backoff, since those errors are
#              usually transient; if no attempt produces a report, the scan
#              fails with a "scan errored" message, never the vulnerabilities
#              one. A scan that never produced a report never passes.
#
# The outcome is written to $GITHUB_OUTPUT as `result=<outcome>` when that is
# set. Exit status: 0 for passed, Trivy's own non-zero status for findings
# (the action's exit-code input), 1 for error.
#
# Inputs (env): SCAN_TYPE (fs|image), TRIVY_IMAGE, SCAN_REF, SCANNERS,
# SEVERITY, EXIT_CODE, OUTPUT_FILE (relative to GITHUB_WORKSPACE),
# TRIVYIGNORES, GITHUB_WORKSPACE.
# Tunables (env, for tests): TRIVY_SCAN_ATTEMPTS (default 3),
# TRIVY_SCAN_RETRY_DELAY (default 15; attempt N waits N times this many
# seconds before the next attempt).
set -euo pipefail

: "${SCAN_TYPE:?SCAN_TYPE is required (fs or image)}"
: "${TRIVY_IMAGE:?TRIVY_IMAGE is required}"
: "${SCAN_REF:?SCAN_REF is required}"
: "${SCANNERS:?SCANNERS is required}"
: "${SEVERITY:?SEVERITY is required}"
: "${EXIT_CODE:?EXIT_CODE is required}"
: "${OUTPUT_FILE:?OUTPUT_FILE is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

attempts="${TRIVY_SCAN_ATTEMPTS:-3}"
delay="${TRIVY_SCAN_RETRY_DELAY:-15}"

case "${SCAN_TYPE}" in
  fs) socket_args=() ;;
  image) socket_args=(-v /var/run/docker.sock:/var/run/docker.sock) ;;
  *)
    echo "::error::scan.sh: unsupported SCAN_TYPE '${SCAN_TYPE}' (expected fs or image)" >&2
    exit 1
    ;;
esac

TRIVYIGNORE_ARGS=""
if [ -n "${TRIVYIGNORES:-}" ]; then
  TRIVYIGNORE_ARGS="--ignorefile ${TRIVYIGNORES}"
fi
export SCAN_TYPE SCANNERS SEVERITY EXIT_CODE OUTPUT_FILE SCAN_REF TRIVYIGNORE_ARGS

report="${GITHUB_WORKSPACE}/${OUTPUT_FILE}"

set_result() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "result=$1" >>"${GITHUB_OUTPUT}"
  fi
}

run_scan() {
  # The script passed to `sh -c` is single-quoted on purpose: it expands the
  # -e variables inside the Trivy container, not here.
  # shellcheck disable=SC2016
  docker run --rm \
    -v "${GITHUB_WORKSPACE}:/workspace" \
    ${socket_args[@]+"${socket_args[@]}"} \
    -w /workspace \
    -e SCAN_TYPE \
    -e SCANNERS \
    -e SEVERITY \
    -e EXIT_CODE \
    -e OUTPUT_FILE \
    -e SCAN_REF \
    -e TRIVYIGNORE_ARGS \
    --entrypoint sh \
    "${TRIVY_IMAGE}" \
    -c '
      set -e
      # Skip the pip-vendored CycloneDX SBOM (pip/_vendor/bom.cdx.json).
      # pip 26.x ships it to describe the packages pip vendors; Trivy
      # would otherwise ingest it and report those vendored packages
      # (e.g. setuptools, msgpack) as findings, though they are pip
      # internals, not part of the scan target attack surface. See #796.
      trivy "$SCAN_TYPE" \
        --scanners "$SCANNERS" \
        --severity "$SEVERITY" \
        --exit-code 0 \
        --format json \
        --output /tmp/trivy-raw.json \
        --skip-files "**/pip/_vendor/bom.cdx.json" \
        $TRIVYIGNORE_ARGS \
        "$SCAN_REF"
      trivy convert \
        --severity "$SEVERITY" \
        --format table \
        --exit-code 0 \
        /tmp/trivy-raw.json
      trivy convert \
        --severity "$SEVERITY" \
        --format sarif \
        --exit-code "$EXIT_CODE" \
        --output "/workspace/$OUTPUT_FILE" \
        /tmp/trivy-raw.json
    '
}

for i in $(seq 1 "${attempts}"); do
  # A report left by an earlier attempt (or anything else) must not stand in
  # for this attempt's.
  rm -f "${report}"

  set +e
  run_scan
  rc=$?
  set -e

  if [ -f "${report}" ]; then
    if [ "${rc}" -eq 0 ]; then
      set_result passed
      exit 0
    fi
    echo "::error::Trivy found ${SEVERITY} vulnerabilities in ${SCAN_REF} (see the table above and ${OUTPUT_FILE})" >&2
    set_result findings
    exit "${rc}"
  fi

  echo "::warning::Trivy scan of ${SCAN_REF} produced no report (exit ${rc}, attempt ${i}/${attempts})" >&2
  if [ "${i}" -lt "${attempts}" ]; then
    backoff=$((i * delay))
    echo "Retrying the scan in ${backoff}s" >&2
    sleep "${backoff}"
  fi
done

echo "::error::Trivy scan errored (no report produced) for ${SCAN_REF} after ${attempts} attempts. This is a scan failure, not a vulnerability finding; see the Trivy errors above." >&2
set_result error
exit 1
