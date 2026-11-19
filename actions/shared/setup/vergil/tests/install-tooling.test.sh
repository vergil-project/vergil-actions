#!/usr/bin/env bash
#
# Behavioural test for install-tooling.sh — the setup action's vergil-tooling
# install, `uv tool install` from one resolved release commit with its lock
# (epic vergil-project/.github#1350, plan Task 8).
#
# Framework-free and developer-runnable, like read-pin.test.sh: run it directly
# with `bash install-tooling.test.sh`. It needs bash, coreutils, tar, gzip,
# sha1sum and sed, plus python3 in /usr/bin or /bin for the missing_pin_fails
# case, which runs the real read-pin.sh: each case runs with only the stubs,
# the temporary root's usr/bin, /usr/bin and /bin on PATH. Every command the
# script could run against the system (git, curl, uv, and apt-get, apt-cache,
# dpkg-query, gpg and sudo, which it must never run) is a stub first on PATH
# that logs its arguments, and the /.dockerenv probe sits under a temporary
# root (the VRG_ROOT seam).
#
# The uv stubs log every uv call with the interpreter variables set at the
# call, simulate a managed-Python download (logged) or its refusal under
# UV_PYTHON_DOWNLOADS=never, and fail any call that would read a uv.toml in
# its working directory (it lacks --no-config).
#
# The script under test is a copy whose pinned uv SHA-256 lines are rewritten to
# the hash of a fake uv tarball the stub curl serves (or to a wrong hash, for
# the mismatch case); the real pins are checked for shape separately.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../install-tooling.sh"

GIT_URL="https://github.com/vergil-project/vergil-tooling"

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

# write_stub <path>: an executable bash script whose body is stdin.
write_stub() {
  {
    echo '#!/usr/bin/env bash'
    cat
  } >"$1"
  chmod +x "$1"
}

# ---------------------------------------------------------------------------
# The uv stub, shared by the fake tarball and the uv-on-PATH stub.
# ---------------------------------------------------------------------------
uv_body="${work}/uv-body"
cat >"$uv_body" <<'STUB'
line="uv $*"
for v in UV_PYTHON UV_PYTHON_PREFERENCE UV_NO_MANAGED_PYTHON UV_PYTHON_INSTALL_DIR UV_PYTHON_DOWNLOADS; do
  [ -n "${!v+x}" ] && line+=" [${v}=${!v}]"
done
echo "$line" >>"$CALLS"
no_config=0
for a in "$@"; do [ "$a" = --no-config ] && no_config=1; done
if [ "$no_config" -eq 0 ] && [ -e uv.toml ]; then
  echo "error: uv.toml: python-downloads = \"never\" forbids the install" >&2
  exit 2
fi
case "${1:-} ${2:-}" in
  "--version "*) echo "uv 0.0.0-fake" ;;
  "tool dir") echo "$FAKE_UV_BIN_DIR" ;;
  "tool install")
    if [ -n "${FAKE_UV_INSTALL_FAIL:-}" ]; then
      echo "error: fake install failure" >&2
      exit 2
    fi
    if ! ls -d "${UV_PYTHON_INSTALL_DIR:-/nonexistent}"/cpython-3.15* >/dev/null 2>&1; then
      if [ "${UV_PYTHON_DOWNLOADS:-}" = never ]; then
        echo "error: No interpreter found for Python 3.15 in managed installations" >&2
        exit 2
      fi
      echo "uv-download cpython-3.15" >>"$CALLS"
    fi
    if [ -z "${FAKE_UV_NO_SHIM:-}" ]; then
      mkdir -p "$FAKE_UV_BIN_DIR"
      printf '#!/usr/bin/env bash\necho user\n' >"$FAKE_UV_BIN_DIR/vrg-whoami"
      chmod +x "$FAKE_UV_BIN_DIR/vrg-whoami"
    fi
    ;;
  "export "*)
    if [ -n "${FAKE_UV_EXPORT_FAIL:-}" ]; then
      echo "error: Unable to find lockfile at uv.lock" >&2
      exit 2
    fi
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%b' "${FAKE_CONSTRAINTS:-click==8.1.8\nrich==14.0.0\n}" >"$out"
    ;;
esac
exit 0
STUB

build_uv_tarball() {
  local d="${work}/uvsrc" t
  for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    mkdir -p "${d}/uv-${t}"
    write_stub "${d}/uv-${t}/uv" <"$uv_body"
    write_stub "${d}/uv-${t}/uvx" <<<'exit 0'
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

# Commands the script must never run: each only logs its call.
for c in apt-get apt-cache dpkg-query gpg sudo; do
  write_stub "${stubs}/${c}" <<STUB
echo "${c} \$*" >>"\$CALLS"
exit 0
STUB
done

# curl ... -o <file> <url>: the fake uv tarball; anything else fails.
write_stub "${stubs}/curl" <<'STUB'
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "curl $url" >>"$CALLS"
case "$url" in
  *uv-*.tar.gz) cp "$FAKE_UV_TARBALL" "$out" ;;
  *) exit 22 ;;
esac
STUB

# git: ls-remote prints $FAKE_GIT_REFS (exit 128 when unset); init, fetch and
# checkout simulate the one-commit fetch (fetch fails on FAKE_GIT_FETCH_FAIL).
write_stub "${stubs}/git" <<'STUB'
echo "git $*" >>"$CALLS"
dir="."
while [ $# -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; -c) shift 2 ;; *) break ;; esac
done
case "${1:-}" in
  ls-remote) [ -n "${FAKE_GIT_REFS:-}" ] || exit 128; cat "$FAKE_GIT_REFS" ;;
  init) mkdir -p "$dir/.git" ;;
  fetch) [ -z "${FAKE_GIT_FETCH_FAIL:-}" ] || exit 128 ;;
  checkout) echo "version = 1" >"$dir/uv.lock" ;;
esac
exit 0
STUB

# uv on PATH (only when a case asks for it).
uvstubs="${work}/uvstubs"
mkdir -p "$uvstubs"
write_stub "${uvstubs}/uv" <"$uv_body"

# ---------------------------------------------------------------------------
# Fixtures and the runner
# ---------------------------------------------------------------------------

# fake_sha <word>: a stable 40-hex SHA for a fixture.
fake_sha() { printf '%s' "$1" | sha1sum | cut -c1-40; }
# The commit a fixture release tag peels to, and the tag object's own SHA.
commit_of() { fake_sha "commit-$1"; }
object_of() { fake_sha "object-$1"; }

# Per-case state, set by new_case.
root=""
case_dir=""
status=0
stderr=""

# new_case: a fresh root (a host runner by default) and state.
new_case() {
  case_dir="$(mktemp -d "${work}/case.XXXXXX")"
  root="${case_dir}/root"
  mkdir -p "${root}/usr/bin" "${case_dir}/runner-temp" "${case_dir}/ws"
  : >"${case_dir}/calls"
  : >"${case_dir}/github-path"
  unset FAKE_GIT_REFS FAKE_GIT_FETCH_FAIL FAKE_UV_INSTALL_FAIL FAKE_UV_EXPORT_FAIL \
    FAKE_UV_NO_SHIM FAKE_CONSTRAINTS
}

as_container() {
  touch "${root}/.dockerenv"
}

# with_git_refs [--lightweight] <tag>...: the tags git ls-remote lists. A
# release tag is annotated by default: its object line and its peeled line.
with_git_refs() {
  local t light=0
  if [ "${1:-}" = --lightweight ]; then
    light=1
    shift
  fi
  export FAKE_GIT_REFS="${case_dir}/git-refs"
  : >"$FAKE_GIT_REFS"
  for t in "$@"; do
    if [ "$light" -eq 1 ]; then
      printf '%s\trefs/tags/%s\n' "$(commit_of "$t")" "$t" >>"$FAKE_GIT_REFS"
    else
      printf '%s\trefs/tags/%s\n%s\trefs/tags/%s^{}\n' \
        "$(object_of "$t")" "$t" "$(commit_of "$t")" "$t" >>"$FAKE_GIT_REFS"
    fi
  done
}

# with_core_python_dir [--empty]: a Vergil image's managed Python directory,
# holding a cpython-3.15 install unless --empty. Prints its path.
with_core_python_dir() {
  local d="${case_dir}/core-python"
  mkdir -p "$d"
  [ "${1:-}" = --empty ] || mkdir -p "${d}/cpython-3.15.0-linux-x86_64-gnu"
  echo "$d"
}

# run_script [--with-uv] [--script <path>] [--env K=V]... -- <args>...
run_script() {
  local path_prefix="$stubs" s="$good_script" extra=() v
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-uv) path_prefix="${uvstubs}:${stubs}"; shift ;;
      --script) s="$2"; shift 2 ;;
      --env) extra+=("$2"); shift 2 ;;
      --) shift; break ;;
    esac
  done
  for v in FAKE_GIT_REFS FAKE_GIT_FETCH_FAIL FAKE_UV_INSTALL_FAIL FAKE_UV_EXPORT_FAIL \
    FAKE_UV_NO_SHIM FAKE_CONSTRAINTS; do
    [ -z "${!v:-}" ] || extra+=("${v}=${!v}")
  done
  local err="${case_dir}/stderr"
  status=0
  (
    cd "${case_dir}/ws"
    env -i HOME="${case_dir}" \
      PATH="${path_prefix}:${root}/usr/bin:/usr/bin:/bin" \
      VRG_ROOT="$root" CALLS="${case_dir}/calls" \
      RUNNER_TEMP="${case_dir}/runner-temp" GITHUB_PATH="${case_dir}/github-path" \
      GITHUB_WORKSPACE="${case_dir}/ws" FAKE_UV_TARBALL="${work}/uv.tar.gz" \
      FAKE_UV_BIN_DIR="${case_dir}/uv-bin" \
      "${extra[@]}" bash "$s" "$@"
  ) >/dev/null 2>"$err" || status=$?
  stderr="$(cat "$err")"
}

calls() { cat "${case_dir}/calls"; }

# calls_normalized: the calls with the case's own paths replaced, so two cases'
# calls compare equal.
calls_normalized() { calls | sed -e "s#${case_dir}#<case>#g" -e 's#/tmp/tmp\.[A-Za-z0-9]*#<tmp>#g'; }

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

# expect_call_count <name> <fixed string> <n>
expect_call_count() {
  local n
  n="$(calls | grep -cF -- "$2" || true)"
  if [ "$n" -ne "$3" ]; then
    fail_case "$1" "expected $3 calls matching '$2', got ${n} (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
}

# install_call: the one `uv tool install` call.
install_call() { calls | grep -E '^uv tool install' | head -n 1; }

expect_nothing_installed() {
  if calls | grep -E '^uv tool install' >/dev/null; then
    fail_case "$1" "uv tool install ran (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
}

expect_no_system_package_calls() {
  if calls | grep -E '^(apt-get|apt-cache|dpkg-query|gpg|sudo) ' >/dev/null; then
    fail_case "$1" "a system package command ran (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
  if calls | grep -F 'vergil-project.github.io' >/dev/null; then
    fail_case "$1" "the vergil package repository was read (calls: $(calls | tr '\n' '|'))"
    return 1
  fi
}

expect_bin_on_github_path() {
  if ! grep -qx "${case_dir}/uv-bin" "${case_dir}/github-path"; then
    fail_case "$1" "uv's tool bin dir is not on GITHUB_PATH: $(tr '\n' '|' <"${case_dir}/github-path")"
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

# No install path names an interpreter path or reads raw content over a CDN.
case_no_interpreter_path_or_cdn() {
  local name="no_interpreter_path_or_cdn_url"
  if grep -nE '/opt/vergil/python|raw\.githubusercontent\.com|vergil-project\.github\.io' "$script" >/dev/null; then
    fail_case "$name" "install-tooling.sh names $(grep -noE '/opt/vergil/python|raw\.githubusercontent\.com|vergil-project\.github\.io' "$script" | head -n 1)"
    return
  fi
  pass_case "$name"
}

case_released_ref_installs_sha_with_constraints() {
  local name="released_ref_installs_sha_with_constraints" sha inst
  new_case
  with_git_refs v2.1.7
  sha="$(commit_of v2.1.7)"
  run_script -- v2.1.7
  expect_status "$name" 0 || return
  # One lookup of the exact tag and its peeled commit.
  expect_call_count "$name" "git ls-remote" 1 || return
  expect_calls "$name" "git ls-remote --tags ${GIT_URL} refs/tags/v2.1.7 refs/tags/v2.1.7^{}" || return
  expect_stderr "$name" "v2.1.7 resolves to v2.1.7 at ${sha}" || return
  # The lock comes from that commit, fetched over git.
  expect_calls "$name" "fetch -q --depth 1 ${GIT_URL} ${sha}" || return
  expect_calls "$name" "uv export --no-config --frozen --no-dev --no-emit-project --no-hashes --format requirements-txt" || return
  inst="$(install_call)"
  case "$inst" in
    "uv tool install --force --no-config --python 3.15 --managed-python -c "*"/constraints.txt vergil-tooling @ git+${GIT_URL}@${sha}") ;;
    *) fail_case "$name" "install call was '${inst}'"; return ;;
  esac
  case "$inst" in
    *"@v2.1.7"* | *"$(object_of v2.1.7)"*) fail_case "$name" "install names the tag, not its commit: ${inst}"; return ;;
  esac
  expect_bin_on_github_path "$name" || return
  expect_stderr "$name" "vrg-* run from ${case_dir}/uv-bin" || return
  pass_case "$name"
}

# A lightweight tag has no peeled line: its own SHA is the commit.
case_exact_lightweight_tag() {
  local name="exact_lightweight_tag_uses_its_sha"
  new_case
  with_git_refs --lightweight v2.1.7
  run_script -- v2.1.7
  expect_status "$name" 0 || return
  expect_calls "$name" "@$(commit_of v2.1.7)" || return
  pass_case "$name"
}

case_exact_tag_missing() {
  local name="exact_tag_missing_fails"
  new_case
  with_git_refs v2.1.6 v2.1.70
  run_script -- v2.1.7
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: no tag v2.1.7 in ${GIT_URL}" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_line_ref_resolves_newest_patch() {
  local name="line_ref_resolves_newest_patch" sha
  new_case
  # Numeric, not lexical, order; other lines and pre-release tags ignored.
  with_git_refs v2.1.9 v2.1.299 v2.1.30 v2.10.400 v2.1.300-rc1
  sha="$(commit_of v2.1.299)"
  run_script -- v2.1
  expect_status "$name" 0 || return
  expect_call_count "$name" "git ls-remote" 1 || return
  expect_calls "$name" "git ls-remote --tags ${GIT_URL} refs/tags/v2.1.*" || return
  expect_stderr "$name" "v2.1 resolves to v2.1.299 at ${sha}" || return
  expect_calls "$name" "fetch -q --depth 1 ${GIT_URL} ${sha}" || return
  expect_calls "$name" "vergil-tooling @ git+${GIT_URL}@${sha}" || return
  expect_no_calls "$name" "@v2.1" || return
  pass_case "$name"
}

case_line_lookup_failure() {
  local name="line_lookup_failure_is_loud"
  new_case
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: could not list the v2.1.* tags of ${GIT_URL}" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_line_no_release() {
  local name="line_with_no_release_fails"
  new_case
  with_git_refs v2.2.1 v2.1.0-rc1
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: no v2.1.Z release tag in ${GIT_URL}" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_container_job_uses_image_python_dir_and_forbids_download() {
  local name="container_job_uses_image_python_dir_and_forbids_download" dir
  new_case; as_container
  with_git_refs v2.1.7
  dir="$(with_core_python_dir)"
  run_script --with-uv --env VERGIL_CORE_PYTHON_DIR="$dir" -- v2.1
  expect_status "$name" 0 || return
  case "$(install_call)" in
    *" [UV_PYTHON_INSTALL_DIR=${dir}] [UV_PYTHON_DOWNLOADS=never]") ;;
    *) fail_case "$name" "install call was '$(install_call)'"; return ;;
  esac
  expect_no_calls "$name" "uv-download" || return
  expect_no_calls "$name" "curl" || return
  expect_bin_on_github_path "$name" || return
  pass_case "$name"
}

case_container_job_without_dir_logs_download() {
  local name="container_job_without_dir_logs_download"
  new_case; as_container
  with_git_refs v2.1.7
  run_script --with-uv -- v2.1
  expect_status "$name" 0 || return
  expect_stderr "$name" "vergil-tooling: no VERGIL_CORE_PYTHON_DIR; uv may download 3.15" || return
  expect_no_calls "$name" "UV_PYTHON_INSTALL_DIR" || return
  expect_no_calls "$name" "UV_PYTHON_DOWNLOADS" || return
  expect_calls "$name" "uv-download cpython-3.15" || return
  pass_case "$name"
}

case_container_job_wrong_dir_fails_not_downloads() {
  local name="container_job_wrong_dir_fails_not_downloads" dir
  # A directory without the 3.15 install: uv refuses, and nothing downloads.
  new_case; as_container
  with_git_refs v2.1.7
  dir="$(with_core_python_dir --empty)"
  run_script --with-uv --env VERGIL_CORE_PYTHON_DIR="$dir" -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: uv tool install of vergil-tooling v2.1.7 ($(commit_of v2.1.7)) failed" || return
  expect_no_calls "$name" "uv-download" || return
  if [ -s "${case_dir}/github-path" ]; then
    fail_case "$name" "GITHUB_PATH was written: $(tr '\n' '|' <"${case_dir}/github-path")"
    return
  fi
  # A path that is not there at all fails before uv is asked.
  new_case; as_container
  with_git_refs v2.1.7
  run_script --with-uv --env VERGIL_CORE_PYTHON_DIR="${case_dir}/missing" -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "VERGIL_CORE_PYTHON_DIR is ${case_dir}/missing, which is not a directory" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_no_apt_calls_on_any_path() {
  local name="no_apt_calls_on_any_path" dir
  local -a runs=(
    "host|v2.1.7" "host|v2.1" "host|develop" "container|v2.1.7" "container|v2.1"
    "container|feature/x" "host-git|v2.1"
  )
  local r where ref
  for r in "${runs[@]}"; do
    where="${r%%|*}"
    ref="${r#*|}"
    new_case
    with_git_refs v2.1.7
    case "$where" in
      container)
        as_container
        dir="$(with_core_python_dir)"
        run_script --env VERGIL_CORE_PYTHON_DIR="$dir" -- "$ref"
        ;;
      host-git) run_script --env INSTALL_SOURCE=git -- "$ref" ;;
      *) run_script -- "$ref" ;;
    esac
    if [ "$status" -ne 0 ]; then
      fail_case "$name" "${where} ${ref}: exit ${status} (stderr: ${stderr})"
      return
    fi
    expect_no_system_package_calls "$name" || return
  done
  pass_case "$name"
}

case_check_expects_uv_bin_dir_not_usr_bin() {
  local name="check_expects_uv_bin_dir_not_usr_bin"
  # A stale packaged /usr/bin/vrg-whoami is on PATH; the uv one comes first.
  new_case
  with_git_refs v2.1.7
  printf '#!/usr/bin/env bash\necho stale\n' >"${root}/usr/bin/vrg-whoami"
  chmod +x "${root}/usr/bin/vrg-whoami"
  run_script -- v2.1.7
  expect_status "$name" 0 || return
  expect_stderr "$name" "vrg-* run from ${case_dir}/uv-bin" || return
  expect_bin_on_github_path "$name" || return
  # The install leaves no vrg-whoami in the bin dir: the stale shim answers,
  # and the check fails on it.
  new_case
  with_git_refs v2.1.7
  printf '#!/usr/bin/env bash\necho stale\n' >"${root}/usr/bin/vrg-whoami"
  chmod +x "${root}/usr/bin/vrg-whoami"
  FAKE_UV_NO_SHIM=1
  run_script -- v2.1.7
  expect_status "$name" 1 || return
  expect_stderr "$name" "vrg-whoami resolves to ${root}/usr/bin/vrg-whoami, not the installed ${case_dir}/uv-bin/vrg-whoami" || return
  if [ -s "${case_dir}/github-path" ] && grep -qx "${case_dir}/uv-bin" "${case_dir}/github-path"; then
    fail_case "$name" "a failed check still added the bin dir to GITHUB_PATH"
    return
  fi
  pass_case "$name"
}

case_install_source_auto_and_git_install_the_same() {
  local name="install_source_auto_and_git_install_the_same" auto_calls git_calls
  new_case
  with_git_refs v2.1.7 v2.1.8
  run_script --with-uv --env INSTALL_SOURCE=auto -- v2.1
  expect_status "$name" 0 || return
  auto_calls="$(calls_normalized)"
  new_case
  with_git_refs v2.1.7 v2.1.8
  run_script --with-uv --env INSTALL_SOURCE=git -- v2.1
  expect_status "$name" 0 || return
  git_calls="$(calls_normalized)"
  if [ "$auto_calls" != "$git_calls" ]; then
    fail_case "$name" "auto: $(tr '\n' '|' <<<"$auto_calls") git: $(tr '\n' '|' <<<"$git_calls")"
    return
  fi
  expect_calls "$name" "@$(commit_of v2.1.8)" || return
  pass_case "$name"
}

case_install_source_other_value_fails() {
  local name="install_source_other_value_fails"
  new_case
  with_git_refs v2.1.7
  run_script --env INSTALL_SOURCE=apt -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "install-source must be auto or git, got 'apt'" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

case_install_runs_with_no_config_and_cleared_uv_vars() {
  local name="install_runs_with_no_config_and_cleared_uv_vars" ref line
  for ref in v2.1.7 develop; do
    new_case; as_container
    with_git_refs v2.1.7
    run_script --with-uv --env UV_PYTHON=/opt/python/3.12/bin/python3 \
      --env UV_PYTHON_PREFERENCE=only-system --env UV_NO_MANAGED_PYTHON=1 -- "$ref"
    expect_status "$name" 0 || return
    expect_no_calls "$name" "[UV_PYTHON=" || return
    expect_no_calls "$name" "[UV_PYTHON_PREFERENCE=" || return
    expect_no_calls "$name" "[UV_NO_MANAGED_PYTHON=" || return
    while IFS= read -r line; do
      case "$line" in
        "uv tool install "* | "uv export "* | "uv tool dir "*)
          case " $line " in
            *" --no-config "*) ;;
            *) fail_case "$name" "${ref}: no --no-config: ${line}"; return ;;
          esac
          ;;
      esac
    done < <(calls)
    case "$(install_call)" in
      *" --python 3.15 --managed-python "*) ;;
      *) fail_case "$name" "${ref}: install call was '$(install_call)'"; return ;;
    esac
  done
  pass_case "$name"
}

case_hostile_uv_toml_changes_nothing() {
  local name="hostile_uv_toml_changes_nothing" ref clean hostile
  for ref in v2.1 develop; do
    new_case; as_container
    with_git_refs v2.1.7
    run_script --with-uv -- "$ref"
    expect_status "$name" 0 || return
    clean="$(calls_normalized)"
    new_case; as_container
    with_git_refs v2.1.7
    printf 'python-downloads = "never"\npython-preference = "only-system"\n' >"${case_dir}/ws/uv.toml"
    printf '[project]\nname = "consumer"\n[tool.uv]\npython-preference = "only-system"\n' >"${case_dir}/ws/pyproject.toml"
    run_script --with-uv -- "$ref"
    expect_status "$name" 0 || return
    hostile="$(calls_normalized)"
    if [ "$clean" != "$hostile" ]; then
      fail_case "$name" "${ref}: calls differ: $(tr '\n' '|' <<<"$clean") vs $(tr '\n' '|' <<<"$hostile")"
      return
    fi
  done
  pass_case "$name"
}

case_failed_install_exits_nonzero_with_named_error() {
  local name="failed_install_exits_nonzero_with_named_error"
  new_case
  with_git_refs v2.1.7
  FAKE_UV_INSTALL_FAIL=1
  run_script -- v2.1
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: uv tool install of vergil-tooling v2.1.7 ($(commit_of v2.1.7)) failed" || return
  expect_no_calls "$name" "uv tool dir" || return
  # A dev ref's failure is named too.
  new_case
  FAKE_UV_INSTALL_FAIL=1
  run_script -- develop
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: uv tool install of vergil-tooling at dev ref develop failed" || return
  pass_case "$name"
}

case_failed_lock_export_exits_nonzero_with_named_error() {
  local name="failed_lock_export_exits_nonzero_with_named_error" sha
  sha="$(commit_of v2.1.7)"
  # The commit fetch fails.
  new_case
  with_git_refs v2.1.7
  FAKE_GIT_FETCH_FAIL=1
  run_script -- v2.1.7
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: lock export of ${sha}: could not fetch the commit from ${GIT_URL}" || return
  expect_nothing_installed "$name" || return
  # uv export finds no lock.
  new_case
  with_git_refs v2.1.7
  FAKE_UV_EXPORT_FAIL=1
  run_script -- v2.1.7
  expect_status "$name" 1 || return
  expect_stderr "$name" "::error::vergil-tooling: lock export of ${sha}: exporting its uv.lock failed" || return
  expect_nothing_installed "$name" || return
  pass_case "$name"
}

# The constraints hold third-party pins only.
case_constraints_naming_the_project_fail() {
  local name="constraints_naming_the_project_fail" c
  for c in 'click==8.1.8\nvergil-tooling==2.1.7\n' 'click==8.1.8\n-e .\n'; do
    new_case
    with_git_refs v2.1.7
    FAKE_CONSTRAINTS="$c"
    run_script -- v2.1.7
    expect_status "$name" 1 || return
    expect_stderr "$name" "the constraints name vergil-tooling itself or an editable install" || return
    expect_nothing_installed "$name" || return
  done
  pass_case "$name"
}

case_dev_ref_installs_unconstrained() {
  local name="dev_ref_installs_unconstrained"
  new_case
  run_script -- develop
  expect_status "$name" 0 || return
  expect_stderr "$name" "dev ref develop" || return
  expect_no_calls "$name" "git ls-remote" || return
  expect_no_calls "$name" "uv export" || return
  if [ "$(install_call)" != "uv tool install --force --no-config --python 3.15 --managed-python vergil-tooling @ git+${GIT_URL}@develop" ]; then
    fail_case "$name" "install call was '$(install_call)'"
    return
  fi
  expect_bin_on_github_path "$name" || return
  pass_case "$name"
}

case_dev_ref_container_uses_image_python_dir() {
  local name="dev_ref_container_uses_image_python_dir" dir
  new_case; as_container
  dir="$(with_core_python_dir)"
  run_script --with-uv --env VERGIL_CORE_PYTHON_DIR="$dir" -- feature/x
  expect_status "$name" 0 || return
  if [ "$(install_call)" != "uv tool install --force --no-config --python 3.15 --managed-python vergil-tooling @ git+${GIT_URL}@feature/x [UV_PYTHON_INSTALL_DIR=${dir}] [UV_PYTHON_DOWNLOADS=never]" ]; then
    fail_case "$name" "install call was '$(install_call)'"
    return
  fi
  expect_no_calls "$name" "curl" || return
  pass_case "$name"
}

# expect_uv_left_on_path: the pinned uv is installed into RUNNER_TEMP and added
# to GITHUB_PATH, so later steps (which have always had uv) still find it.
expect_uv_left_on_path() {
  if [ ! -x "${case_dir}/runner-temp/uv/bin/uv" ]; then
    fail_case "$1" "uv not installed into RUNNER_TEMP/uv/bin"
    return 1
  fi
  if ! grep -qx "${case_dir}/runner-temp/uv/bin" "${case_dir}/github-path"; then
    fail_case "$1" "RUNNER_TEMP/uv/bin not added to GITHUB_PATH"
    return 1
  fi
}

case_released_install_installs_pinned_uv() {
  local name="released_install_installs_pinned_uv"
  new_case
  with_git_refs v2.1.7
  run_script -- v2.1
  expect_status "$name" 0 || return
  expect_calls "$name" "curl https://github.com/astral-sh/uv/releases/download/0." || return
  expect_uv_left_on_path "$name" || return
  pass_case "$name"
}

case_uv_hash_mismatch() {
  local name="uv_hash_mismatch"
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

case_self_repo_host_installs_pinned_uv() {
  local name="self_repo_host_installs_pinned_uv"
  new_case
  printf '[project]\nname = "vergil-tooling"\n' >"${case_dir}/ws/pyproject.toml"
  run_script --
  expect_status "$name" 0 || return
  expect_calls "$name" "curl https://github.com/astral-sh/uv/releases/download/" || return
  # On a host runner the sync names 3.15 and lets uv provide it: no
  # UV_PYTHON_PREFERENCE=only-system, which would bind it to the runner's Python.
  expect_stderr "$name" "host runner: syncing on Python 3.15, provided by uv" || return
  if ! calls | grep -qx -- "uv sync --frozen --group dev --python 3.15"; then
    fail_case "$name" "no exact host uv sync call (calls: $(calls | tr '\n' '|'))"
    return
  fi
  expect_no_calls "$name" "UV_PYTHON_PREFERENCE" || return
  if ! grep -qx "${case_dir}/runner-temp/uv/bin" "${case_dir}/github-path" ||
    ! grep -qx "${case_dir}/ws/.venv/bin" "${case_dir}/github-path"; then
    fail_case "$name" "GITHUB_PATH lacks the uv or .venv bin dir: $(tr '\n' '|' <"${case_dir}/github-path")"
    return
  fi
  expect_no_calls "$name" "uv tool install" || return
  pass_case "$name"
}

# In a container the sync stays on the image's interpreter (issue #1002): it
# pins UV_PYTHON_PREFERENCE=only-system and names no --python.
case_self_repo_container_pins_image_python() {
  local name="self_repo_container_pins_image_python"
  new_case; as_container
  printf '[project]\nname = "vergil-tooling"\n' >"${case_dir}/ws/pyproject.toml"
  run_script --with-uv --
  expect_status "$name" 0 || return
  if ! calls | grep -qx -- "uv sync --frozen --group dev \[UV_PYTHON_PREFERENCE=only-system\]"; then
    fail_case "$name" "no exact container uv sync call (calls: $(calls | tr '\n' '|'))"
    return
  fi
  expect_no_calls "$name" "--python" || return
  if ! grep -qx "${case_dir}/ws/.venv/bin" "${case_dir}/github-path"; then
    fail_case "$name" "GITHUB_PATH lacks the .venv bin dir: $(tr '\n' '|' <"${case_dir}/github-path")"
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
case_no_interpreter_path_or_cdn || true
case_released_ref_installs_sha_with_constraints || true
case_exact_lightweight_tag || true
case_exact_tag_missing || true
case_line_ref_resolves_newest_patch || true
case_line_lookup_failure || true
case_line_no_release || true
case_container_job_uses_image_python_dir_and_forbids_download || true
case_container_job_without_dir_logs_download || true
case_container_job_wrong_dir_fails_not_downloads || true
case_no_apt_calls_on_any_path || true
case_check_expects_uv_bin_dir_not_usr_bin || true
case_install_source_auto_and_git_install_the_same || true
case_install_source_other_value_fails || true
case_install_runs_with_no_config_and_cleared_uv_vars || true
case_hostile_uv_toml_changes_nothing || true
case_failed_install_exits_nonzero_with_named_error || true
case_failed_lock_export_exits_nonzero_with_named_error || true
case_constraints_naming_the_project_fail || true
case_dev_ref_installs_unconstrained || true
case_dev_ref_container_uses_image_python_dir || true
case_released_install_installs_pinned_uv || true
case_uv_hash_mismatch || true
case_self_repo_host_installs_pinned_uv || true
case_self_repo_container_pins_image_python || true
case_missing_pin_fails || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
