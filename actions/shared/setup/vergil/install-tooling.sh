#!/usr/bin/env bash
#
# Install vergil-tooling for the setup action (epic vergil-project/.github#1350,
# plan Task 8). Every install is `uv tool install` from git: nothing reads the
# vergil package repository, and nothing falls back after a failure. The path
# taken is logged, and a failure on it fails the job.
#
#   * Self repo (vergil-tooling's own CI): the checkout is the project under
#     test, so `uv sync` installs it from source. On a host runner it syncs
#     with `--python 3.15` and lets uv provide that interpreter; in a
#     container it keeps UV_PYTHON_PREFERENCE=only-system, so it runs on the
#     image's interpreter (issue #1002).
#   * A released ref, a line (vX.Y) or an exact release (vX.Y.Z): resolved to
#     one commit SHA with a single `git ls-remote`, the peeled commit of the
#     release tag (a line resolves to its newest vX.Y.Z tag, never the moving
#     vX.Y tag). Everything after uses that SHA: the commit's own uv.lock,
#     fetched over git and exported as constraints, and the install of
#     `vergil-tooling @ git+…@<sha>`. The log names the tag and the SHA. A
#     failed lookup, a missing tag, a failed lock export or a failed install
#     fails the job; nothing installs unconstrained or from an older release.
#   * A dev ref (anything else): `uv tool install` from git at that ref,
#     unconstrained.
#
# Every `uv tool install`, and the lock export, runs with --no-config (so no
# uv.toml or [tool.uv] in the working directory, and no user config, can
# change or block it) and with UV_PYTHON, UV_PYTHON_PREFERENCE and
# UV_NO_MANAGED_PYTHON unset; the install names `--python 3.15
# --managed-python`, so it runs on a uv-managed 3.15, never a system
# interpreter. When the job's environment sets VERGIL_CORE_PYTHON_DIR (a
# Vergil image publishes its managed Python's directory there), the install
# uses that directory as UV_PYTHON_INSTALL_DIR with UV_PYTHON_DOWNLOADS=never,
# so a missing or wrong interpreter fails the install instead of downloading
# one. Without it, uv may download 3.15, and the log says so.
#
# The install-source input keeps its two values, auto and git, which now
# install the same way.
#
# After the install, `vrg-*` live in uv's tool bin directory
# (`uv tool dir --bin`), which is added to PATH and GITHUB_PATH. The check
# then requires `vrg-whoami` to resolve to that directory, as later steps
# will see it, and to run.
#
# Every path leaves uv on PATH: later steps (and the scripts they run) rely
# on it. When none is on PATH, uv is installed from its release tarball at
# UV_VERSION, checked against the SHA-256 pinned below, into
# $RUNNER_TEMP/uv/bin (added to GITHUB_PATH). uv is never installed with pip.
#
# The resolve-and-install rules are the same as vergil-tooling's
# `lib/tooling_install.py`, kept equivalent by hand.
#
# Usage: install-tooling.sh [<tag>]
#   <tag> defaults to the [dependencies].vergil pin, read by read-pin.sh. It is
#   not read for the self repo.
#
# Environment:
#   INSTALL_SOURCE           the action's `install-source` input: auto (default) or git
#   VERGIL_CORE_PYTHON_DIR   set by a Vergil image: its managed Python directory
#   RUNNER_TEMP, GITHUB_PATH, GITHUB_WORKSPACE   set by the Actions runner
#
# Test seams (tests/install-tooling.test.sh); unset in real use:
#   VRG_ROOT   filesystem root prefix for the /.dockerenv probe (default "")
set -euo pipefail

# Bump all three together, from the release's uv-<triple>.tar.gz.sha256 files
# (https://github.com/astral-sh/uv/releases).
UV_VERSION="0.12.23"
UV_SHA256_AMD64="9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6"
UV_SHA256_ARM64="6524bd338177ed50d035d39354e12545e993bbeba2ecbddf0480c5b3a81d313f"

GIT_URL="https://github.com/vergil-project/vergil-tooling"
PACKAGE="vergil-tooling"

root="${VRG_ROOT:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf 'vergil-tooling: %s\n' "$*" >&2
}

die() {
  printf '::error::vergil-tooling: %s\n' "$*" >&2
  exit 1
}

# classify <tag>: line, exact or dev (vergil-tooling `vm_packages.classify_ref`).
classify() {
  if [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo exact
  elif [[ "$1" =~ ^v[0-9]+\.[0-9]+$ ]]; then
    echo line
  else
    echo dev
  fi
}

is_self_repo() {
  grep -q '^name = "vergil-tooling"' pyproject.toml 2>/dev/null
}

is_host() {
  [ ! -f "${root}/.dockerenv" ]
}

# ---------------------------------------------------------------------------
# uv
# ---------------------------------------------------------------------------

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    log "using the uv on PATH ($(command -v uv))"
    return
  fi
  local machine triple sha dest tmp
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64)
      triple="x86_64-unknown-linux-gnu"
      sha="$UV_SHA256_AMD64"
      ;;
    aarch64 | arm64)
      triple="aarch64-unknown-linux-gnu"
      sha="$UV_SHA256_ARM64"
      ;;
    *) die "no pinned uv for machine architecture ${machine}" ;;
  esac
  : "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
  : "${GITHUB_PATH:?GITHUB_PATH is not set}"
  dest="${RUNNER_TEMP}/uv/bin"
  log "installing the pinned uv ${UV_VERSION} (${triple}) into ${dest}"
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${triple}.tar.gz"
  if ! printf '%s  %s\n' "$sha" "${tmp}/uv.tar.gz" | sha256sum -c --quiet - >/dev/null 2>&1; then
    rm -rf "$tmp"
    die "uv ${UV_VERSION} (${triple}) does not match its pinned SHA-256 ${sha}"
  fi
  tar -xzf "${tmp}/uv.tar.gz" -C "$tmp" "uv-${triple}/uv" "uv-${triple}/uvx"
  mkdir -p "$dest"
  install -m 0755 "${tmp}/uv-${triple}/uv" "${tmp}/uv-${triple}/uvx" "$dest/"
  rm -rf "$tmp"
  echo "$dest" >>"$GITHUB_PATH"
  export PATH="${dest}:${PATH}"
  uv --version
}

# ---------------------------------------------------------------------------
# The self repo
# ---------------------------------------------------------------------------

self_repo_install() {
  log "the consumer repo is vergil-tooling itself; installing from source (uv sync)"
  ensure_uv
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
  if is_host; then
    # The runner's own Python is not a series vergil-tooling supports: name
    # 3.15 and let uv provide it.
    log "host runner: syncing on Python 3.15, provided by uv"
    uv sync --frozen --group dev --python 3.15
  else
    # A project command, so it honours the repo's uv settings: pin the
    # interpreter source to the image's Python, never a download (issue #1002).
    UV_PYTHON_PREFERENCE=only-system uv sync --frozen --group dev
  fi
  echo "${GITHUB_WORKSPACE}/.venv/bin" >>"$GITHUB_PATH"
}

# ---------------------------------------------------------------------------
# One resolution, one commit
# ---------------------------------------------------------------------------

# resolve_sha <kind> <ref>: resolves a line or exact ref with one
# `git ls-remote` and sets resolved_tag (the vX.Y.Z tag) and resolved_sha (its
# commit). Release tags are annotated, so the commit is the peeled `^{}` entry;
# a lightweight tag has none and names its commit directly.
resolve_sha() {
  local kind="$1" ref="$2" refs tag_re sha name tag peeled newest="" patch best=-1
  local -A tag_object=() tag_commit=()
  if [ "$kind" = line ]; then
    refs="$(git ls-remote --tags "$GIT_URL" "refs/tags/${ref}.*")" ||
      die "could not list the ${ref}.* tags of ${GIT_URL}"
    tag_re="^${ref//./\\.}\\.[0-9]+\$"
  else
    refs="$(git ls-remote --tags "$GIT_URL" "refs/tags/${ref}" "refs/tags/${ref}^{}")" ||
      die "could not look up the tag ${ref} in ${GIT_URL}"
    tag_re="^${ref//./\\.}\$"
  fi
  while read -r sha name; do
    [ -n "${name:-}" ] || continue
    tag="${name#refs/tags/}"
    peeled=0
    if [[ "$tag" == *'^{}' ]]; then
      tag="${tag%'^{}'}"
      peeled=1
    fi
    [[ "$tag" =~ $tag_re ]] || continue
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] ||
      die "git ls-remote of ${GIT_URL} gave '${sha}' for ${tag}, not a commit SHA"
    if [ "$peeled" -eq 1 ]; then
      tag_commit["$tag"]="$sha"
    else
      tag_object["$tag"]="$sha"
    fi
  done <<<"$refs"
  for tag in "${!tag_object[@]}"; do
    patch="${tag##*.}"
    if [ "$patch" -gt "$best" ]; then
      best="$patch"
      newest="$tag"
    fi
  done
  if [ -z "$newest" ]; then
    if [ "$kind" = line ]; then
      die "no ${ref}.Z release tag in ${GIT_URL}"
    fi
    die "no tag ${ref} in ${GIT_URL}"
  fi
  resolved_tag="$newest"
  resolved_sha="${tag_commit[$newest]:-${tag_object[$newest]}}"
}

# lock_export <project dir> <constraints file>: the commit's uv.lock as
# third-party pins only (no vergil-tooling itself, no editable line). Its own
# line, so the uv source guard (ci/toolchain/pin-python's pin.test.sh) can
# exempt exactly this command from the UV_PYTHON_PREFERENCE pin.
lock_export() {
  uv export --no-config --frozen --no-dev --no-emit-project --no-hashes --format requirements-txt --directory "$1" -o "$2" >/dev/null
}

# export_constraints <sha> <work dir>: fetches the commit alone over git and
# writes its uv.lock, exported, to <work dir>/constraints.txt.
export_constraints() {
  local sha="$1" src="$2/src" constraints="$2/constraints.txt"
  log "exporting the uv.lock of ${sha} as constraints"
  mkdir -p "$src"
  git -C "$src" init -q ||
    die "lock export of ${sha}: git init failed"
  git -C "$src" fetch -q --depth 1 "$GIT_URL" "$sha" ||
    die "lock export of ${sha}: could not fetch the commit from ${GIT_URL}"
  git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
    die "lock export of ${sha}: could not check out the fetched commit"
  lock_export "$src" "$constraints" ||
    die "lock export of ${sha}: exporting its uv.lock failed"
  if grep -Eq '^(-e|--editable)([[:space:]]|$)|^vergil-tooling([^[:alnum:]._-]|$)' "$constraints"; then
    die "lock export of ${sha}: the constraints name ${PACKAGE} itself or an editable install"
  fi
}

# ---------------------------------------------------------------------------
# The install
# ---------------------------------------------------------------------------

# python_source: where the managed 3.15 comes from.
python_source() {
  local dir="${VERGIL_CORE_PYTHON_DIR:-}"
  if [ -z "$dir" ]; then
    log "no VERGIL_CORE_PYTHON_DIR; uv may download 3.15"
    return
  fi
  [ -d "$dir" ] ||
    die "VERGIL_CORE_PYTHON_DIR is ${dir}, which is not a directory: the image's managed Python is missing; refusing to download one"
  export UV_PYTHON_INSTALL_DIR="$dir"
  export UV_PYTHON_DOWNLOADS=never
  log "on the image's managed Python in ${dir} (UV_PYTHON_DOWNLOADS=never)"
}

# check_install: vrg-whoami resolves to uv's tool bin directory and runs.
check_install() {
  local bin loc
  bin="$(uv tool dir --bin --no-config)" ||
    die "could not read uv's tool bin directory (uv tool dir --bin)"
  export PATH="${bin}:${PATH}"
  loc="$(command -v vrg-whoami)" ||
    die "vrg-whoami is not on PATH after the install (expected ${bin}/vrg-whoami)"
  if [ "$loc" != "${bin}/vrg-whoami" ]; then
    die "vrg-whoami resolves to ${loc}, not the installed ${bin}/vrg-whoami"
  fi
  "$loc" --mode >/dev/null || die "${bin}/vrg-whoami does not run"
  echo "$bin" >>"$GITHUB_PATH"
  log "vrg-* run from ${bin}"
}

released_install() {
  local ref="$1" kind="$2" work
  resolve_sha "$kind" "$ref"
  log "${ref} resolves to ${resolved_tag} at ${resolved_sha}"
  ensure_uv
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: work is local to this function.
  trap "rm -rf '${work}'" EXIT
  export_constraints "$resolved_sha" "$work"
  python_source
  log "uv tool install from git: ${resolved_tag} (${resolved_sha}), constrained by its uv.lock"
  uv tool install --force --no-config --python 3.15 --managed-python \
    -c "${work}/constraints.txt" "${PACKAGE} @ git+${GIT_URL}@${resolved_sha}" ||
    die "uv tool install of ${PACKAGE} ${resolved_tag} (${resolved_sha}) failed"
  check_install
}

dev_install() {
  local ref="$1"
  log "uv tool install from git: dev ref ${ref}, unconstrained"
  ensure_uv
  python_source
  uv tool install --force --no-config --python 3.15 --managed-python \
    "${PACKAGE} @ git+${GIT_URL}@${ref}" ||
    die "uv tool install of ${PACKAGE} at dev ref ${ref} failed"
  check_install
}

main() {
  local install_source="${INSTALL_SOURCE:-auto}" tag kind
  case "$install_source" in
    auto | git) ;;
    *) die "install-source must be auto or git, got '${install_source}'" ;;
  esac

  if is_self_repo; then
    self_repo_install
    return
  fi

  tag="${1:-}"
  if [ -z "$tag" ]; then
    # read-pin.sh emits the ::error:: annotation itself.
    tag="$(bash "${here}/read-pin.sh")" || exit 1
  fi
  kind="$(classify "$tag")"

  # The interpreter is uv's own 3.15, whatever the job exports for its
  # project's Python. Only this script's own uv commands see the change.
  unset UV_PYTHON UV_PYTHON_PREFERENCE UV_NO_MANAGED_PYTHON

  if [ "$kind" = dev ]; then
    dev_install "$tag"
  else
    released_install "$tag" "$kind"
  fi
}

main "$@"
