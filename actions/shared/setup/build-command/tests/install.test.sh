#!/usr/bin/env bash
#
# Behavioural test for install.sh — the build-command action's fail-closed core.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# and no action here ships a bats/shell harness, so there is no in-pipeline test
# convention to match. This is therefore a self-contained, framework-free,
# developer-runnable harness: run it directly with `bash install.test.sh`.
#
# Each case builds a temporary PATH holding a stub `vrg-container-build-command`
# executable (so no real command is discovered), runs install.sh, and asserts
# the exit code, output, and — crucially — that a failing command is run exactly
# once (fail-closed, NO retry, unlike the system-packages sibling).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_sh="${here}/../install.sh"

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

# make_stub <bin> <script_body> — write a stub vrg-container-build-command that
# emits <script_body> for the --script flag install.sh reads.
make_stub() {
  local bin="$1" script_body="$2"

  cat >"${bin}/vrg-container-build-command" <<EOF
#!/usr/bin/env bash
# Only --script is used by install.sh.
if [ "\${1:-}" = "--script" ]; then
${script_body}
fi
EOF

  chmod +x "${bin}/vrg-container-build-command"
}

# ---------------------------------------------------------------------------
# Case 1: a declared command is executed — the emitted script touches a marker
# file; install.sh runs it via bash -c and exits 0.
# ---------------------------------------------------------------------------
case_declared_runs() {
  local name="declared-command-runs"
  local dir bin marker out rc
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  marker="${dir}/marker"
  mkdir -p "${bin}"
  make_stub "${bin}" "  echo \"touch '${marker}'\""

  set +e
  out="$(PATH="${bin}:${PATH}" bash "${install_sh}" 2>&1)"
  rc=$?
  set -e

  if [ "${rc}" -ne 0 ]; then
    rm -rf "${dir}"
    fail_case "${name}" "expected exit 0, got ${rc}; output: ${out}"
    return
  fi
  if [ ! -e "${marker}" ]; then
    rm -rf "${dir}"
    fail_case "${name}" "declared command did not run (no marker); output: ${out}"
    return
  fi
  rm -rf "${dir}"
  pass_case "${name}"
}

# ---------------------------------------------------------------------------
# Case 2: a failing command — install.sh exits non-zero AND runs the command
# exactly once (NO retry). The command bumps a counter then exits 3; we assert
# the counter is 1.
# ---------------------------------------------------------------------------
case_fail_closed_no_retry() {
  local name="fail-closed-no-retry"
  local dir bin counter out rc calls
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  counter="${dir}/calls"
  mkdir -p "${bin}"
  printf '0' >"${counter}"
  # The emitted script records one invocation, then fails with exit 3.
  make_stub "${bin}" \
    "  echo \"n=\\\$(cat '${counter}'); printf '%s' \\\"\\\$((n + 1))\\\" >'${counter}'; exit 3\""

  set +e
  out="$(PATH="${bin}:${PATH}" bash "${install_sh}" 2>&1)"
  rc=$?
  set -e

  calls="$(cat "${counter}")"
  rm -rf "${dir}"
  if [ "${rc}" -eq 0 ]; then
    fail_case "${name}" "expected non-zero exit, got 0; output: ${out}"
    return
  fi
  if [ "${calls}" -ne 1 ]; then
    fail_case "${name}" "expected exactly 1 call (no retry), got ${calls}; output: ${out}"
    return
  fi
  pass_case "${name}"
}

# ---------------------------------------------------------------------------
# Case 3: no command declared — accessor prints nothing, install.sh skips.
# ---------------------------------------------------------------------------
case_no_command_skip() {
  local name="no-command-skip"
  local dir bin out rc
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  mkdir -p "${bin}"
  # --script prints nothing when no build-command is declared.
  make_stub "${bin}" '  :'

  set +e
  out="$(PATH="${bin}:${PATH}" bash "${install_sh}" 2>&1)"
  rc=$?
  set -e

  rm -rf "${dir}"
  if [ "${rc}" -ne 0 ]; then
    fail_case "${name}" "expected exit 0, got ${rc}; output: ${out}"
    return
  fi
  if ! printf '%s' "${out}" | grep -q "skipping"; then
    fail_case "${name}" "expected a skip message; output: ${out}"
    return
  fi
  pass_case "${name}"
}

case_declared_runs
case_fail_closed_no_retry
case_no_command_skip

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
