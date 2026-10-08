#!/usr/bin/env bash
#
# Install the OS prerequisites of the package toolchain inside a package build
# or install-test container (epic vergil-project/.github#356, issue
# vergil-project/vergil-actions#931).
#
# apt images (ubuntu, debian):
#   1. On x86_64 only, point the Ubuntu archive and security URIs at an apt
#      mirror list, as GitHub's hosted runner images do in
#      images/ubuntu/scripts/build/configure-apt-sources.sh
#      (https://github.com/actions/runner-images/blob/main/images/ubuntu/scripts/build/configure-apt-sources.sh):
#      the URIs become mirror+file:/etc/apt/apt-mirrors.txt, and that file
#      lists, one "<uri><TAB>priority:<n>" entry per line, the same three
#      hosts in the same order and priorities:
#        http://azure.archive.ubuntu.com/ubuntu/    priority:1
#        http://archive.ubuntu.com/ubuntu/          priority:2
#        http://security.ubuntu.com/ubuntu/         priority:3
#      One deliberate difference: runner-images lists the two fallbacks as
#      https://, but a fresh container has no CA certificates until this very
#      script installs ca-certificates, so an https fallback fails with "No
#      system certificates available". http is the image's own default and apt
#      still verifies every index against the archive's signed InRelease.
#      apt tries the in-region Azure mirror first and falls back down the list
#      when it fails, so a failing Azure mirror no longer fails the job, as a
#      hard rewrite to Azure would. The default archive.ubuntu.com alone can
#      stall for many minutes from GitHub's runners. Both the deb822 file
#      (24.04+, /etc/apt/sources.list.d/ubuntu.sources) and the legacy one-line
#      file (/etc/apt/sources.list) are rewritten. arm64 uses ports.ubuntu.com,
#      which none of these mirrors serve, so non-x86_64 sources are left
#      untouched.
#   2. Write /etc/apt/apt.conf.d/80-vergil-fast-fail (3 retries, 20 s
#      timeouts, 60 s dpkg lock wait) so this and every later apt call in the
#      job fails fast instead of hanging on a stalled mirror. It also sets
#      Acquire::Retries::Delay "false": with delayed retries, apt 2.4-2.8
#      (jammy, noble) deadlocks after a mirror-list failover — the fallback's
#      InRelease files arrive and then apt waits forever, timeouts never
#      firing (https://bugs.launchpad.net/ubuntu/+source/apt/+bug/2003851;
#      reproduced deterministically in ubuntu:24.04 with the Azure mirror
#      unreachable, and the signature of vergil-tooling CD run 37678748594).
#   3. Run exactly one `apt-get update` and install every prerequisite the
#      package tooling needs in one call, so vergil-tooling finds them present.
#
# dnf images (UBI): one `dnf install` of the same prerequisites with bounded
# retries and timeouts. Paths are used for curl and gpg, as vergil-tooling
# does: UBI ships curl-minimal, which conflicts with the full curl package, and
# /usr/bin/gpg resolves to whichever package provides it.
#
# Usage: os-prereqs.sh   (must run as root)
#
# Test seams (tests/os-prereqs.test.sh); unset in real use:
#   VRG_OS_ROOT      filesystem root prefix for the /etc files (default "")
#   VRG_OS_ARCH      machine architecture (default `uname -m`)
#   VRG_OS_PKG_MGR   apt or dnf (default: detected from PATH)
set -euo pipefail

# The path apt reads (always the real /etc, whatever VRG_OS_ROOT is) and the
# source URI that points at it.
MIRROR_LIST="/etc/apt/apt-mirrors.txt"
MIRROR_URI="mirror+file:${MIRROR_LIST}"
APT_PACKAGES=(ca-certificates curl git tar gzip gnupg)
DNF_PACKAGES=(ca-certificates /usr/bin/curl /usr/bin/gpg git tar gzip)

root="${VRG_OS_ROOT:-}"
arch="${VRG_OS_ARCH:-$(uname -m)}"

pkg_mgr="${VRG_OS_PKG_MGR:-}"
if [ -z "$pkg_mgr" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    pkg_mgr=apt
  elif command -v dnf >/dev/null 2>&1; then
    pkg_mgr=dnf
  else
    echo "::error::package setup needs apt-get or dnf; found neither in this image" >&2
    exit 1
  fi
fi

# write_mirror_list
# Write the mirror list in runner-images' format and priorities, with http
# fallbacks (see the header). Overwritten, never appended, so a re-run leaves one copy of each
# entry.
write_mirror_list() {
  local file="${root}${MIRROR_LIST}"
  mkdir -p "$(dirname "$file")"
  printf '%s\tpriority:%s\n' \
    'http://azure.archive.ubuntu.com/ubuntu/' 1 \
    'http://archive.ubuntu.com/ubuntu/' 2 \
    'http://security.ubuntu.com/ubuntu/' 3 \
    >"$file"
  echo "os-prereqs: wrote ${file}"
}

# rewrite_sources <file>
# Rewrite archive.ubuntu.com, security.ubuntu.com and azure.archive.ubuntu.com
# URIs (http or https, with or without the trailing slash) to the mirror list.
# Idempotent: mirror+file:/etc/apt/apt-mirrors.txt never matches, since the
# pattern requires an http(s) Ubuntu host. Other hosts (ports.ubuntu.com,
# third-party repos) are left alone.
rewrite_sources() {
  local file="$1" tmp
  tmp="${file}.vergil-tmp"
  sed -E \
    "s#https?://((azure\\.)?archive|security)\\.ubuntu\\.com/ubuntu/?([[:space:]]|\$)#${MIRROR_URI}\\3#g" \
    "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
  echo "os-prereqs: pointed ${file} at ${MIRROR_URI}"
}

configure_apt() {
  local deb822="${root}/etc/apt/sources.list.d/ubuntu.sources"
  local legacy="${root}/etc/apt/sources.list"
  local conf_dir="${root}/etc/apt/apt.conf.d"

  if [ "$arch" = "x86_64" ]; then
    # 24.04+ keeps a comment-only sources.list beside ubuntu.sources, so
    # rewrite whichever files exist rather than picking one. The mirror list
    # is written first, so no source ever points at a missing file.
    local files=() file
    for file in "$deb822" "$legacy"; do
      if [ -f "$file" ]; then
        files+=("$file")
      fi
    done
    if [ "${#files[@]}" -eq 0 ]; then
      echo "os-prereqs: no Ubuntu apt sources file found; mirror left unchanged"
    else
      write_mirror_list
      for file in "${files[@]}"; do
        rewrite_sources "$file"
      done
    fi
  else
    echo "os-prereqs: ${arch} is not x86_64; apt sources left unchanged"
  fi

  mkdir -p "$conf_dir"
  printf '%s\n' \
    'Acquire::Retries "3";' \
    'Acquire::Retries::Delay "false";' \
    'Acquire::http::Timeout "20";' \
    'Acquire::https::Timeout "20";' \
    'DPkg::Lock::Timeout "60";' \
    >"${conf_dir}/80-vergil-fast-fail"
  echo "os-prereqs: wrote ${conf_dir}/80-vergil-fast-fail"
}

case "$pkg_mgr" in
  apt)
    configure_apt
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
    ;;
  dnf)
    dnf install -y --setopt=install_weak_deps=False \
      --setopt=retries=3 --setopt=timeout=20 "${DNF_PACKAGES[@]}"
    ;;
  *)
    echo "::error::os-prereqs.sh: unknown package manager '${pkg_mgr}'" >&2
    exit 1
    ;;
esac
