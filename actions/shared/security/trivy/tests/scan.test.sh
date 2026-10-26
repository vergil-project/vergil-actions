#!/usr/bin/env bash
#
# Behavioural test for scan.sh — the trivy action's scan with retry and its
# passed / findings / error outcomes (issue #1079).
#
# Like system-packages/tests/install.test.sh, this is a self-contained,
# framework-free, developer-runnable harness: run it with `bash scan.test.sh`.
#
# Each case puts a stub `docker` first on PATH. The stub plays one scripted
# outcome per call, read from a plan file:
#   clean    — writes the report and exits 0 (no findings);
#   findings — writes the report and exits 1 (trivy convert --exit-code 1);
#   error    — writes no report and exits 1 (Trivy stopped before reporting,
#              e.g. a dropped layer or DB download).
# It also records each call's arguments so a case can check the docker
# invocation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scan_sh="${here}/../scan.sh"

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

# make_docker_stub <bin> <dir> — the stub reads <dir>/plan (one outcome per
# line, consumed in order) and appends its arguments to <dir>/calls.
make_docker_stub() {
  local bin="$1" dir="$2"
  cat >"${bin}/docker" <<EOF
#!/usr/bin/env bash
n=\$(( \$(wc -l <'${dir}/calls') + 1 ))
# One line per call: the sh -c script argument spans several lines.
printf '%s\n' "\$*" | tr '\n' ' ' >>'${dir}/calls'
echo >>'${dir}/calls'
outcome=\$(sed -n "\${n}p" '${dir}/plan')
report="\${GITHUB_WORKSPACE}/\${OUTPUT_FILE}"
case "\${outcome}" in
  clean) printf '{"runs":[]}\n' >"\${report}"; exit 0 ;;
  findings) printf '{"runs":[{"results":[1]}]}\n' >"\${report}"; exit 1 ;;
  error) echo "FATAL stream error: PROTOCOL_ERROR" >&2; exit 1 ;;
  *) echo "docker stub: no planned outcome for call \${n}" >&2; exit 99 ;;
esac
EOF
  chmod +x "${bin}/docker"
}

# run_case <dir> <scan-type> <attempts> <plan...> — sets rc, out, result,
# calls (number of docker calls) for the caller to assert on.
run_case() {
  local dir="$1" scan_type="$2" tries="$3"
  shift 3
  mkdir -p "${dir}/bin" "${dir}/ws"
  : >"${dir}/calls"
  : >"${dir}/gh-output"
  printf '%s\n' "$@" >"${dir}/plan"
  make_docker_stub "${dir}/bin" "${dir}"

  set +e
  out="$(PATH="${dir}/bin:${PATH}" \
    GITHUB_WORKSPACE="${dir}/ws" GITHUB_OUTPUT="${dir}/gh-output" \
    SCAN_TYPE="${scan_type}" TRIVY_IMAGE=trivy:test SCAN_REF=example/image:tag \
    SCANNERS=vuln SEVERITY=CRITICAL,HIGH EXIT_CODE=1 \
    OUTPUT_FILE=trivy-results.sarif TRIVYIGNORES=.trivyignore \
    TRIVY_SCAN_ATTEMPTS="${tries}" TRIVY_SCAN_RETRY_DELAY=0 \
    bash "${scan_sh}" 2>&1)"
  rc=$?
  set -e
  result="$(sed -n 's/^result=//p' "${dir}/gh-output")"
  calls="$(wc -l <"${dir}/calls" | tr -d ' ')"
}

# expect <name> <want-rc> <want-result> <want-calls> <want-text> [<absent-text>]
expect() {
  local name="$1" want_rc="$2" want_result="$3" want_calls="$4" want_text="$5"
  local absent="${6:-}"
  if [ "${rc}" -ne "${want_rc}" ]; then
    fail_case "${name}" "expected exit ${want_rc}, got ${rc}; output: ${out}"
    return
  fi
  if [ "${result}" != "${want_result}" ]; then
    fail_case "${name}" "expected result=${want_result}, got '${result}'; output: ${out}"
    return
  fi
  if [ "${calls}" -ne "${want_calls}" ]; then
    fail_case "${name}" "expected ${want_calls} scan attempt(s), got ${calls}; output: ${out}"
    return
  fi
  if [ -n "${want_text}" ] && ! printf '%s' "${out}" | grep -qF -- "${want_text}"; then
    fail_case "${name}" "missing '${want_text}'; output: ${out}"
    return
  fi
  if [ -n "${absent}" ] && printf '%s' "${out}" | grep -qF -- "${absent}"; then
    fail_case "${name}" "unexpected '${absent}'; output: ${out}"
    return
  fi
  pass_case "${name}"
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# A clean scan passes on the first attempt.
run_case "${tmp}/clean" image 3 clean
expect clean-passes 0 passed 1 ""

# Real findings fail with the vulnerabilities message and are not retried.
run_case "${tmp}/findings" image 3 findings
expect findings-fail-without-retry 1 findings 1 \
  "Trivy found CRITICAL,HIGH vulnerabilities in example/image:tag" "scan errored"

# A scan that never produces a report is retried, then fails with the
# "scan errored" message, never the vulnerabilities one.
run_case "${tmp}/error" image 3 error error error
expect error-retried-then-fails 1 error 3 \
  "Trivy scan errored (no report produced) for example/image:tag after 3 attempts" \
  "vulnerabilities in"

# A transient error that recovers on retry passes.
run_case "${tmp}/recover" image 3 error clean
expect transient-error-recovers 0 passed 2 "attempt 1/3"

# A transient error followed by real findings reports the findings.
run_case "${tmp}/error-then-findings" image 3 error findings
expect error-then-findings 1 findings 2 "vulnerabilities in example/image:tag"

# A stale report from before the scan cannot stand in for a scan that errored.
mkdir -p "${tmp}/stale/ws"
printf '{"runs":[]}\n' >"${tmp}/stale/ws/trivy-results.sarif"
run_case "${tmp}/stale" image 2 error error
expect stale-report-ignored 1 error 2 "scan errored (no report produced)"

# The image scan mounts the Docker socket; the fs scan does not.
run_case "${tmp}/image-args" image 1 clean
if grep -q 'docker.sock' "${tmp}/image-args/calls"; then
  pass_case image-mounts-docker-socket
else
  fail_case image-mounts-docker-socket "no docker.sock mount: $(cat "${tmp}/image-args/calls")"
fi
run_case "${tmp}/fs-args" fs 1 clean
if grep -q 'docker.sock' "${tmp}/fs-args/calls"; then
  fail_case fs-omits-docker-socket "unexpected docker.sock mount: $(cat "${tmp}/fs-args/calls")"
else
  pass_case fs-omits-docker-socket
fi

# An unsupported scan type is refused before any scan runs.
run_case "${tmp}/bad-type" sbom 3 clean
expect unsupported-scan-type-refused 1 "" 0 "unsupported SCAN_TYPE 'sbom'"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
