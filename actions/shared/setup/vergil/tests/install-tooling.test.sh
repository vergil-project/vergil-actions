#!/usr/bin/env bash
#
# Behavioural test for install-tooling.sh — the setup action's choice of the
# vergil-tooling install path (epic vergil-project/.github#649, plan Task 5).
#
# Framework-free and developer-runnable, like read-pin.test.sh: run it directly
# with `bash install-tooling.test.sh`. It needs bash, coreutils, tar, gzip, awk
# and sed; every command the script would run against the system (apt-get,
# apt-cache, dpkg-query, gpg, curl, sudo, uv) is a stub first on PATH that logs
# its arguments, and every path the script probes or writes sits under a
# temporary root (the VRG_ROOT seam).
#
# The script under test is a copy whose pinned uv SHA-256 lines are rewritten to
# the hash of a fake uv tarball the stub curl serves (or to a wrong hash, for
# the mismatch case); the real pins are checked for shape separately.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../install-tooling.sh"

FINGERPRINT="B3A1D804DC03AB036566A4E367861822166ECABE"
OTHER_FPR="0000000000000000000000000000000000000000"

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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# The fake uv tarball, holding both architectures' directories.
# ---------------------------------------------------------------------------
build_uv_tarball() {
  local d="${work}/uvsrc" t
  for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    mkdir -p "${d}/uv-${t}"
    printf '#!/usr/bin/env bash\necho "uv $*" >>"$CALLS"\n[ "${1:-}" = --version ] && echo "uv 0.0.0-fake"\nexit 0\n' \
      >"${d}/uv-${t}/uv"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${d}/uv-${t}/uvx"
    chmod +x "${d}/uv-${t}/uv" "${d}/uv-${t}/uvx"
  done
  tar -czf "${work}/uv.tar.gz" -C "$d" uv-x86_64-unknown-linux-gnu uv-aarch64-unknown-linux-gnu
}
build_uv_tarball
UV_TARBALL_SHA="$(sha256sum "${work}/uv.tar.gz" | cut -d' ' -f1)"

# make_script <sha>: a copy of install-tooling.sh pinning <sha> for both arches,
# beside a copy of read-pin.sh.
make_script() {
  local dir="${work}/script-$1"
  mkdir -p "$dir"
  sed -e "s/^UV_SHA256_AMD64=.*/UV_SHA256_AMD64=\"$1\"/" \
    -e "s/^UV_SHA256_ARM64=.*/UV_SHA256_ARM64=\"$1\"/" "$script" >"${dir}/install-tooling.sh"
  cp "${here}/../read-pin.sh" "${dir}/read-pin.sh"
  echo "${dir}/install-tooling.sh"
}
good_script="$(make_script "$UV_TARBALL_SHA")"
bad_script="$(make_script "$(printf 'f%.0s' $(seq 64))")"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
stubs="${work}/stubs"
mkdir -p "$stubs"

write_stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"${stubs}/$1"
  chmod +x "${stubs}/$1"
}

# sudo runs the command, logging it.
write_stub sudo 'echo "sudo $*" >>"$CALLS"; exec "$@"'

# dpkg-query -W -f=<fmt> <pkg>: installed when $STATE/dpkg/<pkg> exists.
write_stub dpkg-query 'pkg="${!#}"
if [ -e "$STATE/dpkg/$pkg" ]; then printf "install ok installed"; exit 0; fi
exit 1'

# gpg --show-keys --with-colons <file>: the colons in $FAKE_GPG_OUT.
write_stub gpg 'echo "gpg $*" >>"$CALLS"; cat "$FAKE_GPG_OUT"'

# curl ... -o <file> <url>: the key or the fake uv tarball.
write_stub curl 'out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "curl $url" >>"$CALLS"
case "$url" in
  *.asc) echo "FAKE KEY" >"$out" ;;
  *uv-*.tar.gz) cp "$FAKE_UV_TARBALL" "$out" ;;
  *) exit 22 ;;
esac'

# apt-cache policy vergil-tooling: the candidate in $FAKE_CANDIDATE.
write_stub apt-cache 'echo "apt-cache $*" >>"$CALLS"
printf "vergil-tooling:\n  Installed: (none)\n  Candidate: %s\n" "${FAKE_CANDIDATE:-(none)}"'

# apt-get: logs whether a bootstrap source exists at the call, fails an update
# on request, and simulates the keyring and vergil-tooling installs.
write_stub apt-get 'boot=no
[ -e "$VRG_ROOT/etc/apt/sources.list.d/vergil-bootstrap.sources" ] && boot=yes
echo "apt-get $* [boot=$boot]" >>"$CALLS"
case " $* " in
  *" update "*|*" update") [ -n "${FAKE_APT_UPDATE_FAIL:-}" ] && exit 100 ;;
esac
case " $* " in
  *" install "*vergil-archive-keyring*)
    mkdir -p "$STATE/dpkg" "$VRG_ROOT/etc/apt/sources.list.d" "$VRG_ROOT/usr/share/keyrings"
    touch "$STATE/dpkg/vergil-archive-keyring"
    echo "Types: deb" >"$VRG_ROOT/etc/apt/sources.list.d/vergil.sources"
    echo "KEY" >"$VRG_ROOT/usr/share/keyrings/vergil-archive-keyring.asc" ;;
  *" install "*vergil-tooling*)
    venv="$VRG_ROOT/opt/vergil/vergil-tooling/venv"
    mkdir -p "$venv/bin" "$VRG_ROOT/usr/bin" "$VRG_ROOT/opt/vergil/python/3.15/bin"
    printf "home = %s\n" "${FAKE_VENV_HOME:-$VRG_ROOT/opt/vergil/python/3.15/bin}" >"$venv/pyvenv.cfg"
    printf "#!/usr/bin/env bash\necho user\n" >"$venv/bin/vrg-whoami"
    chmod +x "$venv/bin/vrg-whoami"
    ln -sf "$venv/bin/vrg-whoami" "$VRG_ROOT/usr/bin/vrg-whoami" ;;
esac
exit 0'

# uv on PATH (only when a case asks for it).
uvstubs="${work}/uvstubs"
mkdir -p "$uvstubs"
printf '#!/usr/bin/env bash\necho "uv $*" >>"$CALLS"\nexit 0\n' >"${uvstubs}/uv"
chmod +x "${uvstubs}/uv"

# ---------------------------------------------------------------------------
# Fixtures and the runner
# ---------------------------------------------------------------------------
one_key="${work}/one-key.colons"
printf 'pub:-:4096:1:AAAA:1:::-:::scESC::::::23::0:\nfpr:::::::::%s:\nsub:-:4096:1:BBBB:1::::::s::::::23:\nfpr:::::::::1111111111111111111111111111111111111111:\n' \
  "$FINGERPRINT" >"$one_key"
wrong_key="${work}/wrong-key.colons"
printf 'pub:-:4096:1:AAAA:1:::-:::scESC::::::23::0:\nfpr:::::::::%s:\n' "$OTHER_FPR" >"$wrong_key"
two_keys="${work}/two-keys.colons"
printf 'pub:-:4096:1:AAAA:1:::-:::scESC::::::23::0:\nfpr:::::::::%s:\npub:-:4096:1:CCCC:1:::-:::scESC::::::23::0:\nfpr:::::::::%s:\n' \
  "$FINGERPRINT" "$OTHER_FPR" >"$two_keys"
no_key="${work}/no-key.colons"
printf 'tru::1:0:0:0\n' >"$no_key"

# Per-case state, set by new_case.
root=""
case_dir=""
status=0
stderr=""

# new_case: a fresh root (an Ubuntu noble host by default) and state.
new_case() {
  case_dir="$(mktemp -d "${work}/case.XXXXXX")"
  root="${case_dir}/root"
  mkdir -p "${root}/etc" "${case_dir}/state/dpkg" "${case_dir}/runner-temp" "${case_dir}/ws"
  printf 'NAME="Ubuntu"\nVERSION_CODENAME=noble\n' >"${root}/etc/os-release"
  touch "${case_dir}/state/dpkg/ca-certificates"
  : >"${case_dir}/calls"
  : >"${case_dir}/github-path"
  unset FAKE_CANDIDATE FAKE_APT_UPDATE_FAIL FAKE_VENV_HOME
  export FAKE_GPG_OUT="$one_key"
}

as_container() {
  touch "${root}/.dockerenv"
}

with_vergil_source() {
  mkdir -p "${root}/etc/apt/sources.list.d"
  echo "Types: deb" >"${root}/etc/apt/sources.list.d/vergil.sources"
}

with_core_python() {
  mkdir -p "${root}/opt/vergil/python/${1:-3.15}/bin"
  touch "${root}/opt/vergil/python/${1:-3.15}/bin/python3"
}

# run_script [--with-uv] [--script <path>] [--env K=V]... -- <args>...
run_script() {
  local path_prefix="$stubs" s="$good_script" extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-uv) path_prefix="${uvstubs}:${stubs}"; shift ;;
      --script) s="$2"; shift 2 ;;
      --env) extra+=("$2"); shift 2 ;;
      --) shift; break ;;
    esac
  done
  local err="${case_dir}/stderr"
  status=0
  (
    cd "${case_dir}/ws"
    env -i HOME="${case_dir}" \
      PATH="${path_prefix}:${root}/usr/bin:/usr/bin:/bin" \
      VRG_ROOT="$root" STATE="${case_dir}/state" CALLS="${case_dir}/calls" \
      RUNNER_TEMP="${case_dir}/runner-temp" GITHUB_PATH="${case_dir}/github-path" \
      GITHUB_WORKSPACE="${case_dir}/ws" FAKE_UV_TARBALL="${work}/uv.tar.gz" \
      FAKE_GPG_OUT="$FAKE_GPG_OUT" ${FAKE_CANDIDATE:+FAKE_CANDIDATE="$FAKE_CANDIDATE"} \
      ${FAKE_APT_UPDATE_FAIL:+FAKE_APT_UPDATE_FAIL=1} \
      ${FAKE_VENV_HOME:+FAKE_VENV_HOME="$FAKE_VENV_HOME"} \
      "${extra[@]}" bash "$s" "$@"
  ) >/dev/null 2>"$err" || status=$?
  stderr="$(cat "$err")"
}

calls() { cat "${case_dir}/calls"; }

expect_status() {
  if [ "$status" -ne "$2" ]; then
    fail_case "$1" "expected exit $2, got ${status} (stderr: ${stderr})"
    return 1
  fi
}

expect_stderr() {
  case "$stderr" in
    *"$2"*) ;;
    *) fail_case "$1" "stderr missing '$2' (stderr: ${stderr})"; return 1 ;;
  esac
}

expect_calls() {
  if ! calls | grep -qF -- "$2"; then
    fail_case "$1" "no call matching '$2' (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
}

expect_no_calls() {
  if calls | grep -qF -- "$2"; then
    fail_case "$1" "unexpected call matching '$2' (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
}

expect_nothing_installed() {
  if calls | grep -E '^apt-get .* install .*vergil-tooling' >/dev/null; then
    fail_case "$1" "vergil-tooling was installed (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
  if calls | grep -E '^uv tool install' >/dev/null; then
    fail_case "$1" "uv tool install ran (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
}

expect_no_bootstrap_files() {
  if [ -e "${root}/etc/apt/sources.list.d/vergil-bootstrap.sources" ] ||
    [ -e "${root}/etc/apt/keyrings/vergil-bootstrap.asc" ]; then
    fail_case "$1" "a bootstrap source or key remains"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

case_real_pins_shape() {
  local name="real_uv_pins_are_well_formed"
  if ! grep -Eq '^UV_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$script" ||
    ! grep -Eq '^UV_SHA256_AMD64="[0-9a-f]{64}"$' "$script" ||
    ! grep -Eq '^UV_SHA256_ARM64="[0-9a-f]{64}"$' "$script"; then
    fail_case "$name" "UV_VERSION or a UV_SHA256_* pin is malformed"
    return
  fi
  if grep -nE '(^|[^[:alnum:]_-])pip3?[[:space:]]+install' "$script" >/dev/null; then
    fail_case "$name" "install-tooling.sh runs pip install"
    return
  fi
  pass_case "$name"
}

case_container_packaged() {
  local name="container_packaged"
  new_case; as_container; with_vergil_source; with_core_python
  FAKE_CANDIDATE="2.1.7-1"
  run_script --with-uv -- v2.1
  expect_status "$name" 0 || return
  expect_stderr "$name" "vergil-tooling: packaged install (v2.1)" || return
  expect_calls "$name" "apt-cache policy vergil-tooling" || return
  expect_calls "$name" "install -y vergil-tooling [" || return
  expect_no_calls "$name" "curl" || return
  if ! grep -qx 'Pin: version 2.1.\*' "${root}/etc/apt/preferences.d/vergil-tooling"; then
    fail_case "$name" "pin file does not pin 2.1.*"
    return
  fi
  expect_no_calls "$name" "uv tool install" || return
  pass_case "$name"
}

case_container_uv() {
  local name="container_uv"
  new_case; as_container
  run_script --with-uv -- v2.1
  expect_status "$name" 0 || return
  expect_stderr "$name" "vergil-tooling: uv tool install from git (image without the vergil apt repository)" || return
  expect_calls "$name" "uv tool install vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1" || return
  expect_no_calls "$name" "apt-get" || return
  pass_case "$name"
}

case_container_half_source_only() {
  local name="container_half_source_only"
  new_case; as_container; with_vergil_source
  run_script --with-uv -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "but not a core Python" || return
  expect_stderr "$name" "refusing to guess" || return
  expect_nothing_installed "$name" || return
  expect_no_calls "$name" "apt-get" || return
  pass_case "$name"
}

case_container_half_runtime_only() {
  local name="container_half_runtime_only"
  new_case; as_container; with_core_python
  run_script --with-uv -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "but not the vergil apt source" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_container_candidate_mismatch() {
  local name="container_candidate_mismatch"
  new_case; as_container; with_vergil_source; with_core_python
  FAKE_CANDIDATE="2.2.0-1"
  run_script --with-uv -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "no packaged vergil-tooling matching v2.1" || return
  expect_stderr "$name" "apt candidate: 2.2.0-1" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_container_exact_pins_version() {
  local name="container_exact_pins_version"
  new_case; as_container; with_vergil_source; with_core_python
  FAKE_CANDIDATE="2.1.3-1"
  run_script --with-uv -- v2.1.3
  expect_status "$name" 0 || return
  expect_calls "$name" "install -y vergil-tooling=2.1.3-1" || return
  if ! grep -qx 'Pin: version 2.1.3-1' "${root}/etc/apt/preferences.d/vergil-tooling"; then
    fail_case "$name" "pin file does not pin 2.1.3-1"
    return
  fi
  pass_case "$name"
}

case_container_exact_candidate_mismatch() {
  local name="container_exact_candidate_mismatch"
  new_case; as_container; with_vergil_source; with_core_python
  FAKE_CANDIDATE="2.1.4-1"
  run_script --with-uv -- v2.1.3
  expect_status "$name" 1 || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_container_apt_update_failure() {
  local name="container_apt_update_failure_fails"
  new_case; as_container; with_vergil_source; with_core_python
  FAKE_CANDIDATE="2.1.7-1"
  FAKE_APT_UPDATE_FAIL=1
  run_script --with-uv -- v2.1
  if [ "$status" -eq 0 ]; then
    fail_case "$name" "expected a non-zero exit"
    return
  fi
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_packaged_check_refuses_foreign_interpreter() {
  local name="packaged_check_refuses_foreign_interpreter"
  new_case; as_container; with_vergil_source; with_core_python
  FAKE_CANDIDATE="2.1.7-1"
  FAKE_VENV_HOME="/usr/bin"
  run_script --with-uv -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "not a vergil-python under /opt/vergil/python/" || return
  pass_case "$name"
}

case_host_packaged() {
  local name="host_packaged"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  run_script -- v2.1
  expect_status "$name" 0 || return
  expect_stderr "$name" "packaged install (v2.1) on the host runner" || return
  expect_calls "$name" "curl https://vergil-project.github.io/packages/keys/vergil.asc" || return
  expect_calls "$name" "install -y vergil-archive-keyring [boot=yes]" || return
  expect_calls "$name" "Dir::Etc::sourcelist=${root}/etc/apt/sources.list.d/vergil-bootstrap.sources" || return
  # Run as a non-root user, the privileged calls go through sudo.
  if [ "$(id -u)" -ne 0 ]; then
    expect_calls "$name" "sudo apt-get" || return
  fi
  expect_calls "$name" "install -y vergil-tooling [boot=no]" || return
  # Step 7: a full update once the bootstrap source is gone.
  if ! calls | grep -E '^apt-get( -o [^ ]+)+ update \[boot=no\]$' >/dev/null; then
    fail_case "$name" "no full apt-get update after the bootstrap (calls: $(calls | tr '\n' '|'))"
    return
  fi
  pass_case "$name"
}

case_host_packaged_leaves_no_bootstrap_source() {
  local name="host_packaged_leaves_no_bootstrap_source"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  run_script -- v2.1
  expect_status "$name" 0 || return
  expect_no_bootstrap_files "$name" || return
  pass_case "$name"
}

case_host_bootstrap_source_content() {
  local name="host_bootstrap_source_content"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  # Capture the bootstrap source when the keyring install runs.
  local copy="${case_dir}/boot-copy"
  write_stub apt-get-capture "cp \"\$VRG_ROOT/etc/apt/sources.list.d/vergil-bootstrap.sources\" \"$copy\" 2>/dev/null || true"
  mv "${stubs}/apt-get" "${stubs}/apt-get.real"
  write_stub apt-get "case \" \$* \" in *vergil-archive-keyring*) \"${stubs}/apt-get-capture\" ;; esac; exec \"${stubs}/apt-get.real\" \"\$@\""
  run_script -- v2.1
  mv "${stubs}/apt-get.real" "${stubs}/apt-get"
  rm -f "${stubs}/apt-get-capture"
  expect_status "$name" 0 || return
  local want
  want="$(printf 'Types: deb\nURIs: https://vergil-project.github.io/packages/deb\nSuites: noble\nComponents: main\nSigned-By: %s/etc/apt/keyrings/vergil-bootstrap.asc' "$root")"
  if [ "$(cat "$copy" 2>/dev/null)" != "$want" ]; then
    fail_case "$name" "bootstrap source was '$(cat "$copy" 2>/dev/null)'"
    return
  fi
  pass_case "$name"
}

case_host_fingerprint_mismatch() {
  local name="host_fingerprint_mismatch"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  FAKE_GPG_OUT="$wrong_key"
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "fingerprint mismatch" || return
  expect_nothing_installed "$name" || return
  expect_no_calls "$name" "apt-get" || return
  if [ -e "${root}/etc/apt/sources.list.d/vergil-bootstrap.sources" ]; then
    fail_case "$name" "a bootstrap source was written"
    return
  fi
  pass_case "$name"
}

case_host_two_primary_keys() {
  local name="host_two_primary_keys_first_matches"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  FAKE_GPG_OUT="$two_keys"
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "exactly one primary key, found 2" || return
  expect_nothing_installed "$name" || return
  expect_no_calls "$name" "apt-get" || return
  pass_case "$name"
}

case_host_no_primary_key() {
  local name="host_no_primary_key"
  new_case
  FAKE_GPG_OUT="$no_key"
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "no primary key fingerprint" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_host_candidate_mismatch() {
  local name="host_candidate_mismatch"
  new_case
  FAKE_CANDIDATE="2.2.0-1"
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "no packaged vergil-tooling matching v2.1" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_host_stale_bootstrap_source_removed() {
  local name="host_stale_bootstrap_source_removed"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  mkdir -p "${root}/etc/apt/sources.list.d" "${root}/etc/apt/keyrings"
  echo stale >"${root}/etc/apt/sources.list.d/vergil-bootstrap.sources"
  echo stale >"${root}/etc/apt/keyrings/vergil-bootstrap.asc"
  # A missing prerequisite makes the first apt-get call come before the key
  # download: it must already see no bootstrap source.
  rm -f "${case_dir}/state/dpkg/ca-certificates"
  run_script -- v2.1
  expect_status "$name" 0 || return
  local first
  first="$(calls | grep -m1 '^apt-get ')"
  case "$first" in
    *"update [boot=no]") ;;
    *) fail_case "$name" "first apt-get call saw a bootstrap source: ${first}"; return ;;
  esac
  expect_calls "$name" "install -y ca-certificates [boot=no]" || return
  expect_no_bootstrap_files "$name" || return
  pass_case "$name"
}

case_host_keyring_already_installed() {
  local name="host_keyring_already_installed"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  touch "${case_dir}/state/dpkg/vergil-archive-keyring"
  with_vergil_source
  mkdir -p "${root}/usr/share/keyrings"
  echo KEY >"${root}/usr/share/keyrings/vergil-archive-keyring.asc"
  run_script -- v2.1
  expect_status "$name" 0 || return
  expect_calls "$name" "gpg --show-keys --with-colons ${root}/usr/share/keyrings/vergil-archive-keyring.asc" || return
  expect_no_calls "$name" "curl" || return
  expect_no_calls "$name" "vergil-archive-keyring [" || return
  expect_calls "$name" "install -y vergil-tooling" || return
  pass_case "$name"
}

case_host_installed_key_mismatch() {
  local name="host_installed_key_mismatch"
  new_case
  FAKE_GPG_OUT="$wrong_key"
  touch "${case_dir}/state/dpkg/vergil-archive-keyring"
  with_vergil_source
  mkdir -p "${root}/usr/share/keyrings"
  echo KEY >"${root}/usr/share/keyrings/vergil-archive-keyring.asc"
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "refusing to trust it" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_host_keyring_without_source_reinstalls() {
  local name="host_keyring_without_source_reinstalls"
  new_case
  FAKE_CANDIDATE="2.1.7-1"
  touch "${case_dir}/state/dpkg/vergil-archive-keyring"
  run_script -- v2.1
  expect_status "$name" 0 || return
  expect_calls "$name" "install -y --reinstall vergil-archive-keyring" || return
  pass_case "$name"
}

case_host_unregistered_codename() {
  local name="host_unregistered_codename"
  new_case
  printf 'NAME="Ubuntu"\nVERSION_CODENAME=jammy\n' >"${root}/etc/os-release"
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "codename jammy is not a supported package target" || return
  expect_no_calls "$name" "apt-get" || return
  expect_no_calls "$name" "curl" || return
  pass_case "$name"
}

case_self_repo_host_installs_pinned_uv() {
  local name="self_repo_host_installs_pinned_uv"
  new_case
  printf '[project]\nname = "vergil-tooling"\n' >"${case_dir}/ws/pyproject.toml"
  run_script --
  expect_status "$name" 0 || return
  expect_calls "$name" "curl https://github.com/astral-sh/uv/releases/download/" || return
  expect_calls "$name" "uv sync --frozen --group dev" || return
  if ! grep -qx "${case_dir}/runner-temp/uv/bin" "${case_dir}/github-path" ||
    ! grep -qx "${case_dir}/ws/.venv/bin" "${case_dir}/github-path"; then
    fail_case "$name" "GITHUB_PATH lacks the uv or .venv bin dir: $(tr '\n' '|' <"${case_dir}/github-path")"
    return
  fi
  expect_no_calls "$name" "apt-get" || return
  pass_case "$name"
}

case_install_source_git_line_tag() {
  local name="install_source_git_line_tag"
  new_case
  run_script --env INSTALL_SOURCE=git -- v2.1
  expect_status "$name" 0 || return
  expect_stderr "$name" "install-source: git" || return
  expect_calls "$name" "uv tool install vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.1" || return
  expect_no_calls "$name" "apt-get" || return
  expect_no_calls "$name" "vergil.asc" || return
  pass_case "$name"
}

case_install_source_invalid() {
  local name="install_source_invalid"
  new_case
  run_script --env INSTALL_SOURCE=apt -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "install-source must be auto or git" || return
  pass_case "$name"
}

case_dev_tag_installs_pinned_uv() {
  local name="dev_tag_installs_pinned_uv"
  new_case
  run_script -- develop
  expect_status "$name" 0 || return
  expect_stderr "$name" "dev ref develop" || return
  expect_calls "$name" "curl https://github.com/astral-sh/uv/releases/download/0." || return
  expect_calls "$name" "uv tool install vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@develop" || return
  if [ ! -x "${case_dir}/runner-temp/uv/bin/uv" ]; then
    fail_case "$name" "uv not installed into RUNNER_TEMP/uv/bin"
    return
  fi
  expect_no_calls "$name" "apt-get" || return
  pass_case "$name"
}

case_dev_tag_container_binds_core_python() {
  local name="dev_tag_container_binds_core_python"
  new_case; as_container; with_vergil_source; with_core_python
  run_script --with-uv -- feature/x
  expect_status "$name" 0 || return
  expect_stderr "$name" "uv tool install from git on the core Python (feature/x)" || return
  expect_calls "$name" "uv tool install --python ${root}/opt/vergil/python/3.15/bin/python3 vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@feature/x" || return
  expect_no_calls "$name" "curl" || return
  pass_case "$name"
}

case_dev_tag_container_two_cores_refused() {
  local name="dev_tag_container_two_cores_refused"
  new_case; as_container; with_vergil_source; with_core_python 3.15; with_core_python 3.16
  run_script --with-uv -- develop
  expect_status "$name" 1 || return
  expect_stderr "$name" "found 2 core Pythons" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_dev_tag_container_half_refused() {
  local name="dev_tag_container_half_refused"
  new_case; as_container; with_vergil_source
  run_script --with-uv -- develop
  expect_status "$name" 1 || return
  expect_stderr "$name" "refusing to guess" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_dev_tag_uv_hash_mismatch() {
  local name="dev_tag_uv_hash_mismatch"
  new_case
  run_script --script "$bad_script" -- develop
  expect_status "$name" 1 || return
  expect_stderr "$name" "does not match its pinned SHA-256" || return
  expect_nothing_installed "$name" || return
  if [ -e "${case_dir}/runner-temp/uv/bin/uv" ] || [ -s "${case_dir}/github-path" ]; then
    fail_case "$name" "the unverified uv was installed or added to GITHUB_PATH"
    return
  fi
  pass_case "$name"
}

case_missing_pin_fails() {
  local name="missing_pin_fails"
  new_case
  run_script --
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil.toml not found" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_real_pins_shape || true
case_container_packaged || true
case_container_uv || true
case_container_half_source_only || true
case_container_half_runtime_only || true
case_container_candidate_mismatch || true
case_container_exact_pins_version || true
case_container_exact_candidate_mismatch || true
case_container_apt_update_failure || true
case_packaged_check_refuses_foreign_interpreter || true
case_host_packaged || true
case_host_packaged_leaves_no_bootstrap_source || true
case_host_bootstrap_source_content || true
case_host_fingerprint_mismatch || true
case_host_two_primary_keys || true
case_host_no_primary_key || true
case_host_candidate_mismatch || true
case_host_stale_bootstrap_source_removed || true
case_host_keyring_already_installed || true
case_host_installed_key_mismatch || true
case_host_keyring_without_source_reinstalls || true
case_host_unregistered_codename || true
case_self_repo_host_installs_pinned_uv || true
case_install_source_git_line_tag || true
case_install_source_invalid || true
case_dev_tag_installs_pinned_uv || true
case_dev_tag_container_binds_core_python || true
case_dev_tag_container_two_cores_refused || true
case_dev_tag_container_half_refused || true
case_dev_tag_uv_hash_mismatch || true
case_missing_pin_fails || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
