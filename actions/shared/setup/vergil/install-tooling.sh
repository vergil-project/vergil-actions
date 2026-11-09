#!/usr/bin/env bash
#
# Install vergil-tooling for the setup action (epic vergil-project/.github#649,
# plan Task 5). The install path is chosen by explicit checks, the choice is
# logged, and a failure on the chosen path fails the job: nothing falls back
# after a failure.
#
#   * Self repo (vergil-tooling's own CI): the checkout is the project under
#     test, so `uv sync` installs it from source, as before.
#   * install-source: git (publish-index's build-index, which rebuilds the
#     vergil apt index and so never installs from it): `uv tool install` from
#     git, whatever the tag.
#   * A dev tag (anything but vX.Y or vX.Y.Z): `uv tool install` from git. Where
#     both the vergil apt source and a core Python (/opt/vergil/python/*) are
#     present, it runs on the core Python (`--python`); where neither is,
#     today's command; where only one is, it refuses.
#   * A line (vX.Y) or exact (vX.Y.Z) tag in a container job: the packaged
#     install when the image has both the vergil apt source and a core Python,
#     today's `uv tool install` from git when it has neither, and a refusal when
#     it has only one (the same three-way check as vergil-tooling's cache
#     build).
#   * A line or exact tag in a host job (no /.dockerenv): the vergil apt
#     repository is set up on the runner as vergil-tooling's
#     `lib/package/repo_setup.bootstrap` does (key checked against the pinned
#     primary fingerprint before any source is written), then the packaged
#     install.
#
# A packaged install pins vergil-tooling to the tag in
# /etc/apt/preferences.d/vergil-tooling, checks apt's candidate against the tag
# (prefix X.Y. for a line, exactly X.Y.Z-1 for an exact tag) as `vrg-vm update`
# does (vergil-tooling `lib/vm_packages.packaged_install`), installs it, and
# checks that `vrg-whoami` runs from /usr/bin on a venv whose interpreter lives
# under /opt/vergil/python/.
#
# Whenever a path needs uv and none is on PATH, uv is installed from its release
# tarball at UV_VERSION, checked against the SHA-256 pinned below, into
# $RUNNER_TEMP/uv/bin (added to GITHUB_PATH). uv is never installed with pip.
#
# Usage: install-tooling.sh [<tag>]
#   <tag> defaults to the [dependencies].vergil pin, read by read-pin.sh. It is
#   not read for the self repo.
#
# Environment:
#   INSTALL_SOURCE   the action's `install-source` input: auto (default) or git
#   RUNNER_TEMP, GITHUB_PATH, GITHUB_WORKSPACE   set by the Actions runner
#
# Test seams (tests/install-tooling.test.sh); unset in real use:
#   VRG_ROOT   filesystem root prefix for every probed or written path (default "")
set -euo pipefail

# Bump all three together, from the release's uv-<triple>.tar.gz.sha256 files
# (https://github.com/astral-sh/uv/releases).
UV_VERSION="0.12.23"
UV_SHA256_AMD64="9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6"
UV_SHA256_ARM64="6524bd338177ed50d035d39354e12545e993bbeba2ecbddf0480c5b3a81d313f"

# The vergil org's package repository (vergil-tooling `lib/package/orgs.py`).
VERGIL_BASE_URL="https://vergil-project.github.io/packages"
VERGIL_FINGERPRINT="B3A1D804DC03AB036566A4E367861822166ECABE"
KEYRING_PACKAGE="vergil-archive-keyring"
# The registered deb suites (vergil-tooling `lib/package/targets.py`).
DEB_SUITES="noble resolute"

GIT_URL="https://github.com/vergil-project/vergil-tooling"
PACKAGE="vergil-tooling"

# vergil-tooling `lib/package/repo_setup.APT_FAIL_FAST`.
APT_FAIL_FAST=(
  -o Acquire::Retries=3
  -o Acquire::Retries::Delay=false
  -o Acquire::http::Timeout=20
  -o Acquire::https::Timeout=20
  -o DPkg::Lock::Timeout=60
)

root="${VRG_ROOT:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PERMANENT_SOURCE="${root}/etc/apt/sources.list.d/vergil.sources"
INSTALLED_KEY="${root}/usr/share/keyrings/${KEYRING_PACKAGE}.asc"
BOOTSTRAP_SOURCE="${root}/etc/apt/sources.list.d/vergil-bootstrap.sources"
BOOTSTRAP_KEY="${root}/etc/apt/keyrings/vergil-bootstrap.asc"
PIN_FILE="${root}/etc/apt/preferences.d/vergil-tooling"
CORE_PYTHON_GLOB="/opt/vergil/python/*/bin/python3"

log() {
  printf 'vergil-tooling: %s\n' "$*" >&2
}

die() {
  printf '::error::vergil-tooling: %s\n' "$*" >&2
  exit 1
}

# Run a privileged command: directly as root (container jobs), else with sudo.
priv() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

apt_get() {
  priv apt-get "${APT_FAIL_FAST[@]}" "$@"
}

# write_root_file <dest> <content>: replace a root-owned file atomically. The
# temporary name ends in .vergil-new, which apt never reads as a source or pin.
write_root_file() {
  local dest="$1" content="$2" tmp
  tmp="$(mktemp)"
  printf '%s' "$content" >"$tmp"
  priv install -D -m 0644 "$tmp" "${dest}.vergil-new"
  priv mv -f "${dest}.vergil-new" "$dest"
  rm -f "$tmp"
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
# The environment check
# ---------------------------------------------------------------------------

# Sets core_pythons to every core Python present (zero or more).
find_core_pythons() {
  core_pythons=()
  local p
  for p in ${root}${CORE_PYTHON_GLOB}; do
    [ -e "$p" ] && core_pythons+=("$p")
  done
}

# Prints both, neither, or the refusal message for a half environment.
environment_state() {
  local source=0 runtime=0
  [ -f "$PERMANENT_SOURCE" ] && source=1
  find_core_pythons
  [ "${#core_pythons[@]}" -gt 0 ] && runtime=1
  if [ "$source" -eq 1 ] && [ "$runtime" -eq 1 ]; then
    echo both
  elif [ "$source" -eq 0 ] && [ "$runtime" -eq 0 ]; then
    echo neither
  elif [ "$source" -eq 1 ]; then
    echo "the image has the vergil apt source (/etc/apt/sources.list.d/vergil.sources) but not a core Python (${CORE_PYTHON_GLOB}); refusing to guess"
  else
    echo "the image has a core Python (${CORE_PYTHON_GLOB}) but not the vergil apt source (/etc/apt/sources.list.d/vergil.sources); refusing to guess"
  fi
}

uv_git_install() {
  uv tool install "${PACKAGE} @ git+${GIT_URL}@$1"
}

# ---------------------------------------------------------------------------
# The vergil apt repository on a host runner (repo_setup.bootstrap)
# ---------------------------------------------------------------------------

# primary_fingerprint <key file>: the primary-key fingerprint of a key file
# that holds exactly one primary key (repo_setup.parse_primary_fingerprint).
primary_fingerprint() {
  local colons parsed
  colons="$(gpg --show-keys --with-colons "$1")" || die "gpg could not read the key file $1"
  parsed="$(printf '%s\n' "$colons" | awk -F: '
    $1 == "pub" { n++; fp[n] = ""; expecting = 1; next }
    $1 == "fpr" && expecting { fp[n] = $10; expecting = 0 }
    END {
      if (n > 1) { print "multi " n; exit }
      if (n == 0 || fp[1] == "") { print "none"; exit }
      print "ok " fp[1]
    }')"
  case "$parsed" in
    "ok "*) echo "${parsed#ok }" ;;
    "multi "*)
      die "the key file $1 must hold exactly one primary key, found ${parsed#multi }"
      ;;
    *) die "no primary key fingerprint in the key file $1" ;;
  esac
}

# Prints the registered deb suite this runner's OS is, or fails.
runner_codename() {
  local codename suite
  codename="$(sed -n 's/^VERSION_CODENAME="\{0,1\}\([^"[:space:]]*\)"\{0,1\}$/\1/p' \
    "${root}/etc/os-release" 2>/dev/null | head -n 1)"
  for suite in $DEB_SUITES; do
    if [ "$codename" = "$suite" ]; then
      echo "$codename"
      return
    fi
  done
  die "runner OS codename ${codename:-(unknown)} is not a supported package target (supported: ${DEB_SUITES// /, })"
}

# Prints installed, source and key for what of the keyring package's permanent
# setup is in place (repo_setup.keyring_probe).
keyring_state() {
  if dpkg-query -W -f='${Status}' "$KEYRING_PACKAGE" 2>/dev/null | grep -qx 'install ok installed'; then
    echo installed
  fi
  [ -e "$PERMANENT_SOURCE" ] && echo source
  [ -e "$INSTALLED_KEY" ] && echo key
  return 0
}

bootstrap_vergil_repository() {
  local codename missing state reinstall tmp got rc content
  codename="$(runner_codename)"

  # 1. Bootstrap files a broken earlier run left would make apt reject the
  #    source list next to the keyring's own source: remove them first.
  priv rm -f "$BOOTSTRAP_SOURCE" "$BOOTSTRAP_KEY"

  # The bootstrap prerequisites, installed only when missing.
  missing=()
  dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -qx 'install ok installed' ||
    missing+=(ca-certificates)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v gpg >/dev/null 2>&1 || missing+=(gnupg)
  if [ "${#missing[@]}" -gt 0 ]; then
    log "installing the bootstrap prerequisites: ${missing[*]}"
    apt_get update
    apt_get install -y "${missing[@]}"
  fi

  # 2. The keyring package already in place: check its key, skip the bootstrap.
  state="$(keyring_state | tr '\n' ' ')"
  if [ "$state" = "installed source key " ]; then
    got="$(primary_fingerprint "$INSTALLED_KEY")"
    if [ "$got" != "$VERGIL_FINGERPRINT" ]; then
      die "installed vergil key ${INSTALLED_KEY} has primary fingerprint ${got}, pinned ${VERGIL_FINGERPRINT}: refusing to trust it"
    fi
    log "${KEYRING_PACKAGE} is already installed; its key matches the pinned fingerprint"
    return
  fi
  # Installed without its source or key: only a reinstall re-runs what wrote them.
  reinstall=()
  case "$state" in
    *installed*) reinstall=(--reinstall) ;;
  esac

  # 3. The codename was checked above, before any change.
  # 4. Download the key and check it before anything touches the sources.
  tmp="$(mktemp -d)"
  curl -fsSL "${VERGIL_BASE_URL}/keys/vergil.asc" -o "${tmp}/vergil.asc"
  got="$(primary_fingerprint "${tmp}/vergil.asc")"
  if [ "$got" != "$VERGIL_FINGERPRINT" ]; then
    rm -rf "$tmp"
    die "vergil package key fingerprint mismatch: published ${got}, pinned ${VERGIL_FINGERPRINT} (${VERGIL_BASE_URL}/keys/vergil.asc)"
  fi

  # 5. The bootstrap key and source.
  content="Types: deb
URIs: ${VERGIL_BASE_URL}/deb
Suites: ${codename}
Components: main
Signed-By: ${BOOTSTRAP_KEY}
"
  priv install -D -m 0644 "${tmp}/vergil.asc" "$BOOTSTRAP_KEY"
  rm -rf "$tmp"
  write_root_file "$BOOTSTRAP_SOURCE" "$content"

  # 6. Refresh and install the keyring from the bootstrap source alone, then
  #    remove the bootstrap files whatever the outcome.
  rc=0
  {
    apt_get -o "Dir::Etc::sourcelist=${BOOTSTRAP_SOURCE}" -o Dir::Etc::sourceparts=- \
      -o APT::Get::List-Cleanup=0 update &&
      apt_get -o "Dir::Etc::sourcelist=${BOOTSTRAP_SOURCE}" -o Dir::Etc::sourceparts=- \
        install -y "${reinstall[@]}" "$KEYRING_PACKAGE"
  } || rc=$?
  priv rm -f "$BOOTSTRAP_SOURCE" "$BOOTSTRAP_KEY"
  if [ "$rc" -ne 0 ]; then
    die "installing ${KEYRING_PACKAGE} from the bootstrap source failed (exit ${rc})"
  fi
  state="$(keyring_state | tr '\n' ' ')"
  if [ "$state" != "installed source key " ]; then
    die "installing ${KEYRING_PACKAGE} did not leave its setup in place (found: ${state:-nothing}; source ${PERMANENT_SOURCE}, key ${INSTALLED_KEY})"
  fi
  log "${KEYRING_PACKAGE} installed; the bootstrap source and key are removed"
}

# ---------------------------------------------------------------------------
# The packaged install
# ---------------------------------------------------------------------------

write_pin() {
  local tag="$1" kind="$2" version
  if [ "$kind" = exact ]; then
    version="${tag#v}-1"
  else
    version="${tag#v}.*"
  fi
  write_root_file "$PIN_FILE" "Package: ${PACKAGE}
Pin: version ${version}
Pin-Priority: 1001
"
}

# check_candidate <tag> <kind>: fail unless apt's candidate matches the tag.
check_candidate() {
  local tag="$1" kind="$2" policy candidate ok=0
  policy="$(apt-cache policy "$PACKAGE")"
  candidate="$(printf '%s\n' "$policy" | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
  if [ "$kind" = exact ]; then
    [ "$candidate" = "${tag#v}-1" ] && ok=1
  else
    case "$candidate" in
      "${tag#v}."*) ok=1 ;;
    esac
  fi
  if [ "$ok" -ne 1 ]; then
    die "no packaged ${PACKAGE} matching ${tag} in ${VERGIL_BASE_URL} (apt candidate: ${candidate:-(none)}). Release ${tag} first, or pin a git ref in [dependencies].vergil (a dev install)."
  fi
  log "apt candidate ${candidate} matches ${tag}"
}

# The installed vrg-* commands run from the package, on vergil-python.
verify_packaged() {
  local loc target venv home
  loc="$(command -v vrg-whoami)" || die "vrg-whoami is not on PATH after the packaged install"
  if [ "$loc" != "${root}/usr/bin/vrg-whoami" ]; then
    die "vrg-whoami resolves to ${loc}, not the packaged /usr/bin/vrg-whoami"
  fi
  target="$(readlink -f "$loc")"
  venv="$(dirname "$(dirname "$target")")"
  home="$(sed -n 's/^home[[:space:]]*=[[:space:]]*//p' "${venv}/pyvenv.cfg" 2>/dev/null | head -n 1)"
  case "$home" in
    "${root}"/opt/vergil/python/*) ;;
    *) die "the packaged vrg-whoami runs on ${home:-an unknown interpreter} (${venv}/pyvenv.cfg), not a vergil-python under /opt/vergil/python/" ;;
  esac
  "$loc" --mode >/dev/null || die "the packaged vrg-whoami does not run"
  log "vrg-* run from /usr/bin on ${home}"
}

packaged_install() {
  local tag="$1" kind="$2" spec="$PACKAGE"
  [ "$kind" = exact ] && spec="${PACKAGE}=${tag#v}-1"
  apt_get install -y "$spec"
  verify_packaged
}

# ---------------------------------------------------------------------------
# The paths
# ---------------------------------------------------------------------------

self_repo_install() {
  log "the consumer repo is vergil-tooling itself; installing from source (uv sync)"
  ensure_uv
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
  # A project command, so it honours the repo's uv settings: pin the interpreter
  # source to the image's Python, never a download (issue #1002).
  UV_PYTHON_PREFERENCE=only-system uv sync --frozen --group dev
  echo "${GITHUB_WORKSPACE}/.venv/bin" >>"$GITHUB_PATH"
}

git_source_install() {
  local tag="$1"
  log "uv tool install from git (${tag}; install-source: git, never the vergil apt repository)"
  ensure_uv
  uv_git_install "$tag"
}

dev_install() {
  local tag="$1" state
  state="$(environment_state)"
  case "$state" in
    both)
      find_core_pythons
      if [ "${#core_pythons[@]}" -ne 1 ]; then
        die "found ${#core_pythons[@]} core Pythons (${core_pythons[*]}); cannot tell which is core"
      fi
      log "uv tool install from git on the core Python (${tag})"
      ensure_uv
      # --python overrides any UV_PYTHON the job exports for its family.
      uv tool install --python "${core_pythons[0]}" "${PACKAGE} @ git+${GIT_URL}@${tag}"
      ;;
    neither)
      log "uv tool install from git (dev ref ${tag}; no vergil apt repository or core Python)"
      ensure_uv
      uv_git_install "$tag"
      ;;
    *) die "$state" ;;
  esac
}

container_install() {
  local tag="$1" kind="$2" state
  state="$(environment_state)"
  case "$state" in
    both)
      log "packaged install (${tag})"
      write_pin "$tag" "$kind"
      apt_get update
      check_candidate "$tag" "$kind"
      packaged_install "$tag" "$kind"
      ;;
    neither)
      log "uv tool install from git (image without the vergil apt repository)"
      ensure_uv
      uv_git_install "$tag"
      ;;
    *) die "$state" ;;
  esac
}

host_install() {
  local tag="$1" kind="$2"
  log "packaged install (${tag}) on the host runner, from the vergil apt repository"
  bootstrap_vergil_repository
  # 7. The keyring's own source, refreshed with every other source.
  apt_get update
  write_pin "$tag" "$kind"
  check_candidate "$tag" "$kind"
  packaged_install "$tag" "$kind"
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

  if [ "$install_source" = git ]; then
    git_source_install "$tag"
  elif [ "$kind" = dev ]; then
    dev_install "$tag"
  elif is_host; then
    host_install "$tag" "$kind"
  else
    container_install "$tag" "$kind"
  fi
}

main "$@"
