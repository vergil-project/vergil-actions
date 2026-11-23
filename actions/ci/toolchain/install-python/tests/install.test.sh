#!/usr/bin/env bash
#
# Behavioural test for install.sh — the dev-dependency install of a Python CI
# leg, skipped loudly on a repo not bootstrapped yet (issue #1206) — plus
# structural checks that every Python leg of the CI workflows installs through
# it, after pinning uv, and that no workflow runs `uv sync` itself.
#
# Framework-free and developer-runnable: `bash install.test.sh`. Each case runs
# install.sh in a scratch checkout holding the chosen manifests, with a fake
# `uv` first on PATH that records its arguments and UV_PYTHON_PREFERENCE and
# exits with a chosen status, and asserts the exit status, the output and the
# uv call.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_sh="${here}/../install.sh"
workflows="${here}/../../../../../.github/workflows"

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

rc=0
stdout=""
stderr=""
calls=""

# run_install <uv exit status> [<file in the checkout> ...]
# A name ending in / is created as a directory, any other as a file.
run_install() {
  local uv_rc="$1" work bin so se log path
  shift
  work="$(mktemp -d)"
  bin="$(mktemp -d)"
  so="$(mktemp)"
  se="$(mktemp)"
  log="${bin}/calls.log"
  for path in "$@"; do
    case "$path" in
      */) mkdir -p "${work}/${path}" ;;
      *) printf 'fixture\n' >"${work}/${path}" ;;
    esac
  done
  cat >"${bin}/uv" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\${UV_PYTHON_PREFERENCE:-}" "\$*" >>"${log}"
echo "uv: fake output" >&2
exit ${uv_rc}
EOF
  chmod +x "${bin}/uv"
  rc=0
  (cd "$work" && env -u UV_PYTHON_PREFERENCE PATH="${bin}:${PATH}" bash "$install_sh") \
    >"$so" 2>"$se" || rc=$?
  stdout="$(cat "$so")"
  stderr="$(cat "$se")"
  calls="$(cat "$log" 2>/dev/null || true)"
  rm -rf "$work" "$bin" "$so" "$se"
}

want_sync='only-system|sync --group dev --frozen'

case_unbootstrapped_skips() {
  local name="no-manifests-skips-with-notice"
  run_install 0
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 0
  fi
  case "$stdout" in
    *"::notice title=install-python::skipped: no pyproject.toml, uv.lock (python repo not bootstrapped yet)"*) ;;
    *)
      fail_case "$name" "expected the skip notice, got '${stdout}'"
      return 0
      ;;
  esac
  if [ -n "$calls" ]; then
    fail_case "$name" "uv was called on an unbootstrapped repo: '${calls}'"
    return 0
  fi
  pass_case "$name"
}

# A directory is not a manifest: the repo is still unbootstrapped.
case_manifest_directories_skip() {
  local name="manifest-named-directories-still-skip"
  run_install 0 pyproject.toml/ uv.lock/
  if [ "$rc" -ne 0 ] || [ -n "$calls" ]; then
    fail_case "$name" "expected a skip, got rc=${rc}, uv calls '${calls}'"
    return 0
  fi
  pass_case "$name"
}

# expect_sync <name> <uv exit status> <files...> — uv sync runs, pinned to the
# image's interpreter, and the step exits with uv's status.
expect_sync() {
  local name="$1" uv_rc="$2"
  shift 2
  run_install "$uv_rc" "$@"
  if [ "$calls" != "$want_sync" ]; then
    fail_case "$name" "expected one uv call '${want_sync}', got '${calls}'"
    return 0
  fi
  if [ "$rc" -ne "$uv_rc" ]; then
    fail_case "$name" "expected exit ${uv_rc}, got ${rc}; stderr: ${stderr}"
    return 0
  fi
  case "$stdout" in
    *"::notice"*)
      fail_case "$name" "printed the skip notice on a repo with a manifest: '${stdout}'"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_bootstrapped_installs() {
  expect_sync "bootstrapped-installs" 0 pyproject.toml uv.lock
}

case_bootstrapped_install_fails() {
  expect_sync "bootstrapped-install-failure-fails" 2 pyproject.toml uv.lock
}

# A partial bootstrap is not skipped: uv sync runs and its failure fails the
# step, as vrg-validate fails it.
case_pyproject_only_runs_sync() {
  expect_sync "pyproject-only-runs-sync-and-fails" 2 pyproject.toml
}

case_lock_only_runs_sync() {
  expect_sync "uv-lock-only-runs-sync-and-fails" 2 uv.lock
}

# Every Python leg installs through this action, after pinning uv, and no
# workflow runs uv sync itself (which would fail an unbootstrapped repo).
case_workflows_install_every_python_leg() {
  local name="workflows-install-every-python-leg"
  local wf installs pins legs=0
  for wf in "$workflows"/*.yml; do
    if grep -Eq '^[[:space:]]*(-[[:space:]]+)?run:.*uv sync' "$wf"; then
      fail_case "$name" "$(basename "$wf") runs uv sync itself; use ./actions/ci/toolchain/install-python"
      return 0
    fi
    installs="$(grep -c 'uses: ./actions/ci/toolchain/install-python$' "$wf" || true)"
    pins="$(grep -c 'uses: ./actions/ci/toolchain/pin-python$' "$wf" || true)"
    if [ "$installs" != "$pins" ]; then
      fail_case "$name" "$(basename "$wf") has ${pins} pin-python step(s) but ${installs} install-python step(s)"
      return 0
    fi
    legs=$((legs + installs))
    # In each job, the install follows the pin.
    if ! awk '
      /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { pinned = 0 }
      /uses: \.\/actions\/ci\/toolchain\/pin-python$/ { pinned = 1 }
      /uses: \.\/actions\/ci\/toolchain\/install-python$/ && !pinned { bad = 1 }
      END { exit bad }
    ' "$wf"; then
      fail_case "$name" "$(basename "$wf") installs before it pins uv in a job"
      return 0
    fi
  done
  # ci-quality lint + typecheck + custom + build, ci-audit dependencies,
  # ci-test unit.
  if [ "$legs" -ne 6 ]; then
    fail_case "$name" "expected 6 Python install steps, found ${legs}"
    return 0
  fi
  pass_case "$name"
}

case_unbootstrapped_skips
case_manifest_directories_skip
case_bootstrapped_installs
case_bootstrapped_install_fails
case_pyproject_only_runs_sync
case_lock_only_runs_sync
case_workflows_install_every_python_leg

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
