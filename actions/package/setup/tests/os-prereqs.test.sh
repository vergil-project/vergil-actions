#!/usr/bin/env bash
#
# Behavioural test for os-prereqs.sh — the package setup action's OS
# prerequisites installer (apt mirror list on x86_64, fail-fast apt, one
# apt-get update; bounded dnf on UBI).
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash os-prereqs.test.sh`. It needs no root and touches no
# real /etc: each case builds a fixture root (VRG_OS_ROOT), fixes the
# architecture (VRG_OS_ARCH) and puts recording apt-get/dnf stubs first on
# PATH, then asserts the rewritten files and the recorded package-manager
# calls.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../os-prereqs.sh"

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

# assert_eq <name> <what> <actual> <expected>
assert_eq() {
  if [ "$3" = "$4" ]; then
    return 0
  fi
  fail_case "$1" "$2: expected
---
$4
---
got
---
$3
---"
  return 1
}

# The ubuntu:24.04 image's deb822 sources (amd64 flavour; comments trimmed).
NOBLE_AMD64_SOURCES='Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'

NOBLE_AMD64_EXPECTED='Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'

# The same sources as left by this script's earlier hard rewrite to the Azure
# mirror (and as GitHub's own runner images ship them): Azure URIs must move to
# the mirror list too.
NOBLE_AZURE_SOURCES='Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'

# The ubuntu:24.04 image's deb822 sources (arm64 flavour; comments trimmed).
NOBLE_ARM64_SOURCES='Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'

# A legacy one-line sources.list (ubuntu:22.04 style) plus a third-party line
# and a no-trailing-slash URI, both of which must survive correctly.
JAMMY_SOURCES='deb http://archive.ubuntu.com/ubuntu/ jammy main restricted
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted
deb http://security.ubuntu.com/ubuntu/ jammy-security main restricted
deb https://example.com/apt stable main'

JAMMY_EXPECTED='deb mirror+file:/etc/apt/apt-mirrors.txt jammy main restricted
deb mirror+file:/etc/apt/apt-mirrors.txt jammy-updates main restricted
deb mirror+file:/etc/apt/apt-mirrors.txt jammy-security main restricted
deb https://example.com/apt stable main'

# GitHub runner-images configure-apt-sources.sh format, "<uri><TAB>priority:<n>",
# with http (not https) fallbacks: a fresh container has no CA certificates yet.
TAB="$(printf '\t')"
MIRROR_LIST_EXPECTED="http://azure.archive.ubuntu.com/ubuntu/${TAB}priority:1
http://archive.ubuntu.com/ubuntu/${TAB}priority:2
http://security.ubuntu.com/ubuntu/${TAB}priority:3"

FAST_FAIL_EXPECTED='Acquire::Retries "3";
Acquire::Retries::Delay "false";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
DPkg::Lock::Timeout "60";'

APT_LOG_EXPECTED='apt-get update DEBIAN_FRONTEND=noninteractive fast-fail=present
apt-get install -y --no-install-recommends ca-certificates curl git tar gzip gnupg DEBIAN_FRONTEND=noninteractive fast-fail=present'

DNF_LOG_EXPECTED='dnf install -y --setopt=install_weak_deps=False --setopt=retries=3 --setopt=timeout=20 ca-certificates /usr/bin/curl /usr/bin/gpg git tar gzip'

# make_env
# Echoes a fresh temp dir holding root/ (the fixture filesystem root), bin/
# (recording apt-get and dnf stubs) and calls.log (what the stubs saw). The
# apt-get stub also records whether the fail-fast file already existed, which
# proves it is written before the first apt call.
# The stub bodies are single-quoted on purpose: their $variables expand when
# the stub runs, not here.
# shellcheck disable=SC2016
make_env() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/root/etc/apt/sources.list.d" "${dir}/bin"
  : >"${dir}/calls.log"
  printf '%s\n' \
    "#!${BASH}" \
    'ff=absent' \
    '[ -f "${VRG_OS_ROOT}/etc/apt/apt.conf.d/80-vergil-fast-fail" ] && ff=present' \
    'echo "apt-get $* DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-} fast-fail=${ff}" >>"${CALLS_LOG}"' \
    >"${dir}/bin/apt-get"
  printf '%s\n' \
    "#!${BASH}" \
    'echo "dnf $*" >>"${CALLS_LOG}"' \
    >"${dir}/bin/dnf"
  chmod +x "${dir}/bin/apt-get" "${dir}/bin/dnf"
  printf '%s' "$dir"
}

# run_script <env dir> <arch> <pkg mgr or ""> — runs os-prereqs.sh in the env.
run_script() {
  local dir="$1"
  env PATH="${dir}/bin:${PATH}" CALLS_LOG="${dir}/calls.log" \
    VRG_OS_ROOT="${dir}/root" VRG_OS_ARCH="$2" VRG_OS_PKG_MGR="$3" \
    bash "$script" >/dev/null
}

# assert_apt_tail <name> <env dir> — fail-fast file and the apt call sequence.
assert_apt_tail() {
  local name="$1" dir="$2"
  assert_eq "$name" "80-vergil-fast-fail" \
    "$(cat "${dir}/root/etc/apt/apt.conf.d/80-vergil-fast-fail")" \
    "$FAST_FAIL_EXPECTED" || return 1
  assert_eq "$name" "apt calls" "$(cat "${dir}/calls.log")" "$APT_LOG_EXPECTED"
}

# assert_mirror_list <name> <env dir> — the mirror list exists, byte-exact.
assert_mirror_list() {
  local file="${2}/root/etc/apt/apt-mirrors.txt"
  if [ ! -f "$file" ]; then
    fail_case "$1" "apt-mirrors.txt was not written"
    return 1
  fi
  assert_eq "$1" "apt-mirrors.txt" "$(cat "$file")" "$MIRROR_LIST_EXPECTED"
}

# assert_no_mirror_list <name> <env dir> — no mirror list was written.
assert_no_mirror_list() {
  if [ -e "${2}/root/etc/apt/apt-mirrors.txt" ]; then
    fail_case "$1" "apt-mirrors.txt was written but no sources were rewritten"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Case 1: deb822 ubuntu.sources on x86_64 -> archive and security URIs both
# move to the mirror list, which is written; one update, one install,
# fail-fast first.
# ---------------------------------------------------------------------------
case_deb822_x86_64() {
  local name="deb822-x86_64" dir src
  dir="$(make_env)"
  src="${dir}/root/etc/apt/sources.list.d/ubuntu.sources"
  printf '%s\n' "$NOBLE_AMD64_SOURCES" >"$src"
  run_script "$dir" x86_64 apt
  assert_eq "$name" "ubuntu.sources" "$(cat "$src")" "$NOBLE_AMD64_EXPECTED" &&
    assert_mirror_list "$name" "$dir" &&
    assert_apt_tail "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 1b: sources already hard-pointed at the Azure mirror (this script's
# earlier behaviour, and GitHub's runner-image default) -> mirror list too.
# ---------------------------------------------------------------------------
case_azure_to_mirror_list() {
  local name="azure-to-mirror-list" dir src
  dir="$(make_env)"
  src="${dir}/root/etc/apt/sources.list.d/ubuntu.sources"
  printf '%s\n' "$NOBLE_AZURE_SOURCES" >"$src"
  run_script "$dir" x86_64 apt
  assert_eq "$name" "ubuntu.sources" "$(cat "$src")" "$NOBLE_AMD64_EXPECTED" &&
    assert_mirror_list "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 2: aarch64 -> ports.ubuntu.com sources untouched, but fail-fast and the
# single update/install still apply.
# ---------------------------------------------------------------------------
case_deb822_aarch64() {
  local name="deb822-aarch64" dir src
  dir="$(make_env)"
  src="${dir}/root/etc/apt/sources.list.d/ubuntu.sources"
  printf '%s\n' "$NOBLE_ARM64_SOURCES" >"$src"
  run_script "$dir" aarch64 apt
  assert_eq "$name" "ubuntu.sources" "$(cat "$src")" "$NOBLE_ARM64_SOURCES" &&
    assert_no_mirror_list "$name" "$dir" &&
    assert_apt_tail "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 3: x86_64 even with archive.ubuntu.com URIs is the only arch rewritten:
# an aarch64 run over amd64-style sources leaves them alone.
# ---------------------------------------------------------------------------
case_non_x86_64_never_rewrites() {
  local name="aarch64-never-rewrites" dir src
  dir="$(make_env)"
  src="${dir}/root/etc/apt/sources.list.d/ubuntu.sources"
  printf '%s\n' "$NOBLE_AMD64_SOURCES" >"$src"
  run_script "$dir" aarch64 apt
  assert_eq "$name" "ubuntu.sources" "$(cat "$src")" "$NOBLE_AMD64_SOURCES" &&
    assert_no_mirror_list "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 4: legacy one-line sources.list on x86_64 -> rewritten, with the
# no-trailing-slash URI normalised and a third-party line untouched.
# ---------------------------------------------------------------------------
case_legacy_x86_64() {
  local name="legacy-sources-list-x86_64" dir src
  dir="$(make_env)"
  src="${dir}/root/etc/apt/sources.list"
  printf '%s\n' "$JAMMY_SOURCES" >"$src"
  run_script "$dir" x86_64 apt
  assert_eq "$name" "sources.list" "$(cat "$src")" "$JAMMY_EXPECTED" &&
    assert_mirror_list "$name" "$dir" &&
    assert_apt_tail "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 5: running twice leaves the rewritten sources unchanged and the mirror
# list with exactly one copy of each entry (overwritten, not appended).
# ---------------------------------------------------------------------------
case_idempotent() {
  local name="idempotent" dir src
  dir="$(make_env)"
  src="${dir}/root/etc/apt/sources.list.d/ubuntu.sources"
  printf '%s\n' "$NOBLE_AMD64_SOURCES" >"$src"
  run_script "$dir" x86_64 apt
  run_script "$dir" x86_64 apt
  assert_eq "$name" "ubuntu.sources" "$(cat "$src")" "$NOBLE_AMD64_EXPECTED" &&
    assert_mirror_list "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 5b: x86_64 with no Ubuntu sources file (e.g. a Debian image) -> no
# mirror list is written; fail-fast and the single update/install still apply.
# ---------------------------------------------------------------------------
case_no_sources_x86_64() {
  local name="no-sources-x86_64" dir
  dir="$(make_env)"
  run_script "$dir" x86_64 apt
  assert_no_mirror_list "$name" "$dir" &&
    assert_apt_tail "$name" "$dir" && pass_case "$name"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 6: UBI / dnf -> one bounded dnf install with path-form curl and gpg;
# no apt files written, apt-get never called.
# ---------------------------------------------------------------------------
case_dnf() {
  local name="dnf-ubi" dir
  dir="$(make_env)"
  run_script "$dir" x86_64 dnf
  if [ -e "${dir}/root/etc/apt/apt.conf.d" ]; then
    fail_case "$name" "dnf path wrote apt configuration"
  else
    assert_eq "$name" "dnf calls" "$(cat "${dir}/calls.log")" "$DNF_LOG_EXPECTED" &&
      pass_case "$name"
  fi
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Case 7: package-manager detection prefers apt-get, falls back to dnf, and
# fails loudly when the image has neither.
# ---------------------------------------------------------------------------
case_detection() {
  local name="detection" dir rc=0
  dir="$(make_env)"
  rm "${dir}/bin/apt-get"
  # A PATH holding only the stub dir hides the host's real apt-get.
  env PATH="${dir}/bin" CALLS_LOG="${dir}/calls.log" \
    VRG_OS_ROOT="${dir}/root" VRG_OS_ARCH=x86_64 \
    "$BASH" "$script" >/dev/null
  assert_eq "$name" "dnf fallback" "$(cat "${dir}/calls.log")" "$DNF_LOG_EXPECTED" || {
    rm -rf "$dir"
    return
  }
  rm "${dir}/bin/dnf"
  env PATH="${dir}/bin" VRG_OS_ROOT="${dir}/root" VRG_OS_ARCH=x86_64 \
    "$BASH" "$script" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected a nonzero exit with neither apt-get nor dnf"
    return
  fi
  pass_case "$name"
}

case_deb822_x86_64
case_azure_to_mirror_list
case_deb822_aarch64
case_non_x86_64_never_rewrites
case_legacy_x86_64
case_idempotent
case_no_sources_x86_64
case_dnf
case_detection

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
