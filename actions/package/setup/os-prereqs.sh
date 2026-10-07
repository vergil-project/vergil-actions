#!/usr/bin/env bash
#
# Install the OS prerequisites of the package toolchain inside a package build
# or install-test container (epic vergil-project/.github#356, issue
# vergil-project/vergil-actions#931).
#
# apt images (ubuntu, debian):
#   1. On x86_64 only, point the Ubuntu archive and security URIs at the Azure
#      mirror GitHub's hosted runner images use
#      (http://azure.archive.ubuntu.com/ubuntu/). The default archive.ubuntu.com
#      can stall for many minutes from GitHub's runners; the Azure mirror is
#      in-region. Both the deb822 file (24.04+,
#      /etc/apt/sources.list.d/ubuntu.sources) and the legacy one-line file
#      (/etc/apt/sources.list) are rewritten. arm64 uses ports.ubuntu.com, which
#      the Azure mirror does not serve, so non-x86_64 sources are left untouched.
#   2. Write /etc/apt/apt.conf.d/80-vergil-fast-fail (3 retries, 20 s
#      timeouts) so this and every later apt call in the job fails fast
#      instead of hanging on a stalled mirror.
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

AZURE_MIRROR="http://azure.archive.ubuntu.com/ubuntu/"
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

# rewrite_sources <file>
# Rewrite archive.ubuntu.com and security.ubuntu.com URIs (http or https, with
# or without the trailing slash) to the Azure mirror. Idempotent: the Azure
# host itself never matches, since the pattern requires "://" directly before
# "archive" or "security". Other hosts (ports.ubuntu.com, third-party repos)
# are left alone.
rewrite_sources() {
  local file="$1" tmp
  tmp="${file}.vergil-tmp"
  sed -E \
    "s#https?://(archive|security)\\.ubuntu\\.com/ubuntu/?([[:space:]]|\$)#${AZURE_MIRROR}\\2#g" \
    "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
  echo "os-prereqs: pointed ${file} at ${AZURE_MIRROR}"
}

configure_apt() {
  local deb822="${root}/etc/apt/sources.list.d/ubuntu.sources"
  local legacy="${root}/etc/apt/sources.list"
  local conf_dir="${root}/etc/apt/apt.conf.d"

  if [ "$arch" = "x86_64" ]; then
    # 24.04+ keeps a comment-only sources.list beside ubuntu.sources, so
    # rewrite whichever files exist rather than picking one.
    local found=0 file
    for file in "$deb822" "$legacy"; do
      if [ -f "$file" ]; then
        rewrite_sources "$file"
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "os-prereqs: no Ubuntu apt sources file found; mirror left unchanged"
    fi
  else
    echo "os-prereqs: ${arch} is not x86_64; apt sources left unchanged"
  fi

  mkdir -p "$conf_dir"
  printf '%s\n' \
    'Acquire::Retries "3";' \
    'Acquire::http::Timeout "20";' \
    'Acquire::https::Timeout "20";' \
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
