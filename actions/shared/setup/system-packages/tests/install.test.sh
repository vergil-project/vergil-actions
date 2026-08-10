#!/usr/bin/env bash
#
# Behavioural test for install.sh — the system-packages action's retry +
# fail-closed core.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# and no action here ships a bats/shell harness, so there is no in-pipeline test
# convention to match. This is therefore a self-contained, framework-free,
# developer-runnable harness: run it directly with `bash install.test.sh`.
#
# Each case builds a temporary PATH holding stub `vrg-container-system-packages`
# and `apt-get` executables (so nothing real is installed), runs install.sh, and
# asserts the exit code and output. The accessor stub emits the exact snippet
# shape the real `vrg-container-system-packages --install-script` produces
# (vergil-tooling: apt_install_command), so the fail-closed message under test is
# the production one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_sh="${here}/../install.sh"

pass=0
fail=0

# fail_case <name> <reason>
fail_case() {
  printf 'not ok - %s: %s\n' "$1" "$2" >&2
  fail=$((fail + 1))
}

pass_case() {
  printf 'ok - %s\n' "$1"
  pass=$((pass + 1))
}

# make_bin <dir> — write the two stubs into <dir> from the caller-provided
# APT_BODY and SCRIPT_BODY snippets, and make them executable.
make_stubs() {
  local bin="$1" apt_body="$2" script_body="$3"

  cat >"${bin}/vrg-container-system-packages" <<EOF
#!/usr/bin/env bash
# Only --install-script is used by install.sh.
if [ "\${1:-}" = "--install-script" ]; then
${script_body}
fi
EOF

  cat >"${bin}/apt-get" <<EOF
#!/usr/bin/env bash
${apt_body}
EOF

  chmod +x "${bin}/vrg-container-system-packages" "${bin}/apt-get"
}

# Snippet the real accessor emits for a single installable package `jq`.
installable_script='  echo "apt-get update && { apt-get install -y --no-install-recommends jq || { echo \"system package jq is not installable on linux/amd64 (apt: no installation candidate)\" >&2; exit 1; } }"'

# Snippet the real accessor emits for a bogus package name (fail-closed path).
bogus_script='  echo "apt-get update && { apt-get install -y --no-install-recommends nonexistent-vergil-pkg || { echo \"system package nonexistent-vergil-pkg is not installable on linux/amd64 (apt: no installation candidate)\" >&2; exit 1; } }"'

# ---------------------------------------------------------------------------
# Case 1: a declared, installable package — happy path exits 0.
# ---------------------------------------------------------------------------
case_install_success() {
  local name="install-success"
  local dir bin out rc
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  mkdir -p "${bin}"
  # apt-get always succeeds.
  make_stubs "${bin}" 'exit 0' "${installable_script}"

  set +e
  out="$(PATH="${bin}:${PATH}" SYSTEM_PACKAGES_ATTEMPTS=3 SYSTEM_PACKAGES_RETRY_DELAY=0 \
    bash "${install_sh}" 2>&1)"
  rc=$?
  set -e

  rm -rf "${dir}"
  if [ "${rc}" -ne 0 ]; then
    fail_case "${name}" "expected exit 0, got ${rc}; output: ${out}"
    return
  fi
  pass_case "${name}"
}

# ---------------------------------------------------------------------------
# Case 2: a bogus package — fail-closed, non-zero exit with the "not
# installable" message visible after the retries are exhausted.
# ---------------------------------------------------------------------------
case_fail_closed_bogus() {
  local name="fail-closed-bogus"
  local dir bin out rc
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  mkdir -p "${bin}"
  # `update` succeeds; any `install` fails (no candidate for the bogus name).
  # The stub body is written verbatim into the apt-get stub, so it must stay
  # single-quoted (no expansion here) — that is the intent, not a bug.
  # shellcheck disable=SC2016
  make_stubs "${bin}" \
    'case "${1:-}" in update) exit 0 ;; install) exit 100 ;; *) exit 0 ;; esac' \
    "${bogus_script}"

  set +e
  out="$(PATH="${bin}:${PATH}" SYSTEM_PACKAGES_ATTEMPTS=2 SYSTEM_PACKAGES_RETRY_DELAY=0 \
    bash "${install_sh}" 2>&1)"
  rc=$?
  set -e

  rm -rf "${dir}"
  if [ "${rc}" -eq 0 ]; then
    fail_case "${name}" "expected non-zero exit, got 0; output: ${out}"
    return
  fi
  if ! printf '%s' "${out}" | grep -q "not installable"; then
    fail_case "${name}" "missing fail-closed message; output: ${out}"
    return
  fi
  pass_case "${name}"
}

# ---------------------------------------------------------------------------
# Case 3: a transient apt flake — the first attempt fails, a later one
# succeeds, so install.sh exits 0 and reports the retried attempt.
# ---------------------------------------------------------------------------
case_retry_then_success() {
  local name="retry-then-success"
  local dir bin out rc counter
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  counter="${dir}/apt-calls"
  mkdir -p "${bin}"
  printf '0' >"${counter}"
  # The very first apt-get invocation (attempt 1's `update`) fails, short-
  # circuiting the &&-chain; every later invocation succeeds.
  make_stubs "${bin}" \
    "n=\$(cat '${counter}'); n=\$((n + 1)); printf '%s' \"\${n}\" >'${counter}'; if [ \"\${n}\" -eq 1 ]; then exit 1; fi; exit 0" \
    "${installable_script}"

  set +e
  out="$(PATH="${bin}:${PATH}" SYSTEM_PACKAGES_ATTEMPTS=3 SYSTEM_PACKAGES_RETRY_DELAY=0 \
    bash "${install_sh}" 2>&1)"
  rc=$?
  set -e

  rm -rf "${dir}"
  if [ "${rc}" -ne 0 ]; then
    fail_case "${name}" "expected exit 0 after retry, got ${rc}; output: ${out}"
    return
  fi
  if ! printf '%s' "${out}" | grep -q "attempt 1/3 failed"; then
    fail_case "${name}" "expected a reported first-attempt failure; output: ${out}"
    return
  fi
  pass_case "${name}"
}

# ---------------------------------------------------------------------------
# Case 4: no packages declared — accessor prints nothing, install.sh skips.
# ---------------------------------------------------------------------------
case_no_packages_skip() {
  local name="no-packages-skip"
  local dir bin out rc
  dir="$(mktemp -d)"
  bin="${dir}/bin"
  mkdir -p "${bin}"
  # --install-script prints nothing when no packages are declared.
  make_stubs "${bin}" 'exit 0' '  :'

  set +e
  out="$(PATH="${bin}:${PATH}" SYSTEM_PACKAGES_RETRY_DELAY=0 \
    bash "${install_sh}" 2>&1)"
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

case_install_success
case_fail_closed_bogus
case_retry_then_success
case_no_packages_skip

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
