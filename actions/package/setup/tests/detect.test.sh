#!/usr/bin/env bash
#
# Behavioural test for detect.sh — the package setup action's vergil-tooling
# install-spec resolver — and for the action's "Install vergil-tooling" step
# that runs it.
#
# This repo declares `language = shell` (vergil.toml), which runs no test gate,
# so this is a self-contained, framework-free, developer-runnable harness: run
# it directly with `bash detect.test.sh`. It needs uv on PATH: detect.sh reads
# vergil.toml with the real uv, and the cases for the repo's uv settings
# (issue #1003) test that path and fail without it. They may download a
# managed Python 3.15 into a temp dir when no system 3.15 is on PATH, as in
# the package images. It makes no network call of its own: `git` (ls-remote,
# the commit fetch) and `uv export` are stubs, first on PATH.
#
# Each detect.sh case writes fixture pyproject.toml / vergil.toml files into a
# temp dir, runs `detect.sh <dir> <constraints file>` against it, and asserts
# the printed spec, the constraints file it wrote (or did not), the stub calls
# it made, or the failure.
#
# detect.sh takes the driver Python from VRG_DRIVER_PYTHON, which the action
# sets from its `python` input. The harness exports it for every case; the
# driver-python cases unset it or check that uv is given it.
#
# The step cases take the action.yml step's `run:` script as written and run
# it under bash with a stub detect.sh (as GITHUB_ACTION_PATH), a stub uv and
# stub vrg-* commands, so they test the install line the action really runs.
set -euo pipefail

driver_python="3.15"
export VRG_DRIVER_PYTHON="$driver_python"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
detect_sh="${here}/../detect.sh"
action_yml="${here}/../action.yml"
real_uv="$(command -v uv || true)"

url="https://github.com/vergil-project/vergil-tooling"
sha_9="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
sha_10="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
sha_2="cccccccccccccccccccccccccccccccccccccccc"
sha_light="dddddddddddddddddddddddddddddddddddddddd"
lock_body='cffi==2.1.1
    # via cryptography
cryptography==50.0.2
    # via vergil-tooling'

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

# assert_eq <name> <actual> <expected>
assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    return 0
  fi
  fail_case "$name" "expected '$expected', got '$actual'"
  return 1
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) return 0 ;;
  esac
  fail_case "$1" "expected '$3' in '$2'"
  return 1
}

# assert_lacks <name> <haystack> <needle>
assert_lacks() {
  case "$2" in
    *"$3"*)
      fail_case "$1" "did not expect '$3' in '$2'"
      return 1
      ;;
  esac
  return 0
}

# fixture <pyproject.toml body or ""> <vergil.toml body or "">
# Echoes a fresh temp dir holding the non-empty fixture files.
fixture() {
  local dir
  dir="$(mktemp -d)"
  [ -z "$1" ] || printf '%s\n' "$1" >"${dir}/pyproject.toml"
  [ -z "$2" ] || printf '%s\n' "$2" >"${dir}/vergil.toml"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Stubs for detect.sh: `git` and `uv`, first on PATH.
#
# git: `ls-remote` prints $STUB_LS_REMOTE (a file) and exits
# $STUB_LS_REMOTE_RC; `-C <dir> init` makes <dir>; `-C <dir> fetch` exits
# $STUB_FETCH_RC; `-C <dir> checkout` writes <dir>/uv.lock unless
# $STUB_NO_LOCK is set. Any other call fails. Every call is logged.
#
# uv: `export` writes $STUB_EXPORT_BODY (or the lock body) to its -o file and
# exits $STUB_EXPORT_RC, logging its argv and its working directory; `run`
# prints $STUB_UV_REF when set, else runs the real uv. Every call is logged.
# ---------------------------------------------------------------------------
stubs="$(mktemp -d)"
trap 'rm -rf "$stubs"' EXIT

cat >"${stubs}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$STUB_LOG"
dir=""
if [ "$1" = -C ]; then
  dir="$2"
  shift 2
fi
case "$1" in
  ls-remote)
    cat "$STUB_LS_REMOTE"
    exit "${STUB_LS_REMOTE_RC:-0}"
    ;;
  init) mkdir -p "$dir" ;;
  fetch) exit "${STUB_FETCH_RC:-0}" ;;
  checkout)
    [ -n "${STUB_NO_LOCK:-}" ] || printf 'version = 1\n' >"${dir}/uv.lock"
    ;;
  *)
    echo "git stub: unexpected call: $*" >&2
    exit 97
    ;;
esac
EOF

cat >"${stubs}/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'uv %s\n' "$*" >>"$STUB_LOG"
case "$1" in
  export)
    printf 'export-cwd %s\n' "$PWD" >>"$STUB_LOG"
    [ -f uv.lock ] || { echo "uv stub: no uv.lock in $PWD" >&2; exit 2; }
    rc="${STUB_EXPORT_RC:-0}"
    [ "$rc" -eq 0 ] || { echo "uv stub: export failed" >&2; exit "$rc"; }
    out=""
    while [ "$#" -gt 0 ]; do
      [ "$1" != -o ] || out="$2"
      shift
    done
    printf '%s\n' "${STUB_EXPORT_BODY:-$STUB_LOCK_BODY}" >"$out"
    ;;
  run)
    if [ -n "${STUB_UV_REF:-}" ]; then
      echo "$STUB_UV_REF"
      exit 0
    fi
    [ -n "$STUB_REAL_UV" ] || { echo "uv stub: no real uv on PATH" >&2; exit 98; }
    exec "$STUB_REAL_UV" "$@"
    ;;
  *)
    echo "uv stub: unexpected call: $*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "${stubs}/git" "${stubs}/uv"

# The tags of the line, as the real `git ls-remote --tags` prints them:
# annotated tags (each with its tag object and its peeled ^{} commit), one
# lightweight tag, a pre-release and a tag of another line, which a line pin
# must skip.
ls_remote_fixture="${stubs}/ls-remote"
cat >"$ls_remote_fixture" <<EOF
1111111111111111111111111111111111111111	refs/tags/v2.1.2
${sha_2}	refs/tags/v2.1.2^{}
2222222222222222222222222222222222222222	refs/tags/v2.1.9
${sha_9}	refs/tags/v2.1.9^{}
3333333333333333333333333333333333333333	refs/tags/v2.1.10
${sha_10}	refs/tags/v2.1.10^{}
${sha_light}	refs/tags/v2.1.7
4444444444444444444444444444444444444444	refs/tags/v2.1.11-rc1
5555555555555555555555555555555555555555	refs/tags/v2.1.11-rc1^{}
EOF

export STUB_REAL_UV="$real_uv" STUB_LOCK_BODY="$lock_body"

# run_detect <repo dir> [VAR=value ...]
# Runs `detect.sh <repo dir> <constraints file>` with the stubs first on PATH
# and the given variables set. Sets out, err, rc, cfile (the constraints
# path), calls (the stub log) and work (a temp dir the caller removes).
run_detect() {
  local dir="$1"
  shift
  work="$(mktemp -d)"
  cfile="${work}/constraints.txt"
  : >"${work}/log"
  rc=0
  out="$(env PATH="${stubs}:${PATH}" STUB_LOG="${work}/log" \
    STUB_LS_REMOTE="$ls_remote_fixture" "$@" \
    bash "$detect_sh" "$dir" "$cfile" 2>"${work}/err")" || rc=$?
  err="$(cat "${work}/err")"
  calls="$(cat "${work}/log")"
}

# ---------------------------------------------------------------------------
# test_self_repo_still_installs_checkout: the vergil-tooling repo itself
# installs from its own checkout, with no constraints file and no git call.
# ---------------------------------------------------------------------------
case_self_repo() {
  local name="test_self_repo_still_installs_checkout" dir
  dir="$(fixture '[project]
name = "vergil-tooling"
version = "2.1.227"' '[dependencies]
vergil = "v2.1"')"
  run_detect "$dir"
  rm -rf "$dir" "$work"
  assert_eq "$name" "$rc" 0 || return
  assert_eq "$name" "$out" "$dir" || return
  [ ! -e "$cfile" ] || { fail_case "$name" "a constraints file was written"; return; }
  assert_eq "$name" "$calls" "" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# test_line_pin_prints_sha_spec: a vX.Y pin installs the commit of the newest
# vX.Y.Z tag (v2.1.10, not v2.1.9 by string order, nor the pre-release), named
# by its SHA, never by the tag. It reads vergil.toml with the real uv, even in
# a repo with a pyproject.toml of its own.
# ---------------------------------------------------------------------------
case_line_pin() {
  local name="test_line_pin_prints_sha_spec" dir
  dir="$(fixture '[project]
name = "vergil-python"' '[project]
repository-type = "library"

[dependencies]
vergil = "v2.1"')"
  run_detect "$dir"
  rm -rf "$dir" "$work"
  assert_eq "$name" "$rc" 0 || return
  assert_eq "$name" "$out" "vergil-tooling @ git+${url}@${sha_10}" || return
  assert_contains "$name" "$calls" "git ls-remote --tags ${url} refs/tags/v2.1.*" || return
  assert_contains "$name" "$err" "v2.1 resolves to v2.1.10 at ${sha_10}" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# test_exact_pin_prints_commit_sha: a vX.Y.Z pin installs that tag's commit:
# the peeled ^{} SHA of an annotated tag, the tag's own SHA of a lightweight
# one. A non-Python consumer (no pyproject.toml).
# ---------------------------------------------------------------------------
case_exact_pin() {
  local name="test_exact_pin_prints_commit_sha" dir tag expect
  for tag in v2.1.9 v2.1.7; do
    expect="$sha_9"
    [ "$tag" = v2.1.9 ] || expect="$sha_light"
    dir="$(fixture '' "[dependencies]
vergil = \"${tag}\"")"
    run_detect "$dir"
    rm -rf "$dir" "$work"
    assert_eq "$name" "$rc" 0 || return
    assert_eq "$name" "$out" "vergil-tooling @ git+${url}@${expect}" || return
    assert_contains "$name" "$calls" \
      "git ls-remote --tags ${url} refs/tags/${tag} refs/tags/${tag}^{}" || return
  done
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# test_install_is_constrained_by_the_commit_lock: a released pin's constraints
# file is the uv.lock of the one resolved commit, fetched over git by that
# SHA (one ls-remote, no second resolution) and exported with the project and
# dev groups left out.
# ---------------------------------------------------------------------------
case_constrained_by_commit_lock() {
  local name="test_install_is_constrained_by_the_commit_lock" dir body n_ls
  dir="$(fixture '' '[dependencies]
vergil = "v2.1"')"
  run_detect "$dir"
  body="$(cat "$cfile" 2>/dev/null || true)"
  rm -rf "$dir" "$work"
  assert_eq "$name" "$rc" 0 || return
  assert_eq "$name" "$body" "$lock_body" || return
  n_ls="$(printf '%s\n' "$calls" | grep -c 'ls-remote' || true)"
  assert_eq "$name" "$n_ls" 1 || return
  assert_contains "$name" "$calls" "fetch -q --depth 1 ${url} ${sha_10}" || return
  assert_contains "$name" "$calls" \
    "uv export --no-config --frozen --no-dev --no-emit-project --no-hashes --format requirements-txt -o ${cfile}" || return
  assert_contains "$name" "$err" "constraints: the uv.lock of v2.1.10 (${sha_10})" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# test_dev_ref_installs_unconstrained: a dev ref installs as written, with no
# constraints file and no git call.
# ---------------------------------------------------------------------------
case_dev_ref() {
  local name="test_dev_ref_installs_unconstrained" dir
  dir="$(fixture '' '[dependencies]
vergil = "feature/x"')"
  run_detect "$dir"
  rm -rf "$dir" "$work"
  assert_eq "$name" "$rc" 0 || return
  assert_eq "$name" "$out" "vergil-tooling @ git+${url}@feature/x" || return
  [ ! -e "$cfile" ] || { fail_case "$name" "a constraints file was written"; return; }
  assert_lacks "$name" "$calls" "git " || return
  pass_case "$name"
}

# expect_detect_failure <name> <dir> <stderr needle> [VAR=value ...]
# Asserts detect.sh exits 1 against <dir>, prints nothing on stdout, leaves
# no constraints file and names the failure on stderr.
expect_detect_failure() {
  local name="$1" dir="$2" needle="$3"
  shift 3
  run_detect "$dir" "$@"
  rm -rf "$dir" "$work"
  if [ "$rc" -ne 1 ]; then
    fail_case "$name" "expected exit 1, got ${rc} (stdout '${out}', stderr '${err}')"
    return 1
  fi
  assert_eq "$name" "$out" "" || return
  [ ! -e "$cfile" ] || { fail_case "$name" "a constraints file was left"; return 1; }
  assert_contains "$name" "$err" "$needle" || return
  pass_case "$name"
}

line_dir() {
  fixture '' '[dependencies]
vergil = "v2.1"'
}

# ---------------------------------------------------------------------------
# Failures: each is loud and named, never an unconstrained or older install.
# ---------------------------------------------------------------------------
case_missing_vergil_toml() {
  expect_detect_failure "missing-vergil-toml" "$(fixture '' '')" "vergil.toml not found"
}

case_missing_dependency() {
  expect_detect_failure "missing-dependency" "$(fixture '' '[project]
repository-type = "library"')" "[dependencies].vergil is missing or empty"
}

case_ls_remote_failure() {
  expect_detect_failure "test_ls_remote_failure_is_loud" "$(line_dir)" \
    "could not list the v2.1.* tags of ${url}" STUB_LS_REMOTE_RC=128
}

case_no_tag_on_line() {
  expect_detect_failure "test_no_tag_on_the_line_is_loud" "$(fixture '' '[dependencies]
vergil = "v3.0"')" "no v3.0.Z release tag in ${url}"
}

case_exact_tag_missing() {
  expect_detect_failure "test_missing_exact_tag_is_loud" "$(fixture '' '[dependencies]
vergil = "v2.1.99"')" "no commit SHA for v2.1.99 in ${url}"
}

case_fetch_failure() {
  expect_detect_failure "test_failed_commit_fetch_exits_nonzero_with_named_error" "$(line_dir)" \
    "could not fetch commit ${sha_10} of ${url} to read its uv.lock" STUB_FETCH_RC=128
}

case_no_lock() {
  expect_detect_failure "test_commit_without_lock_exits_nonzero_with_named_error" "$(line_dir)" \
    "commit ${sha_10} of ${url} has no uv.lock" STUB_NO_LOCK=1
}

case_export_failure() {
  expect_detect_failure "test_failed_lock_export_exits_nonzero_with_named_error" "$(line_dir)" \
    "exporting the uv.lock of commit ${sha_10} failed" STUB_EXPORT_RC=2
}

case_export_names_project() {
  local body
  for body in 'vergil-tooling==2.1.10' '-e .' './src' 'cffi==2.1.1
vergil-tooling @ git+https://example.invalid/x'; do
    expect_detect_failure "test_constraints_exclude_the_project" "$(line_dir)" \
      "names the project or a path; refusing it as constraints" \
      STUB_EXPORT_BODY="$body" || return
  done
}

# ---------------------------------------------------------------------------
# The constraints path must not exist beforehand, so a stale file can never
# constrain an install detect.sh did not resolve; it is required.
# ---------------------------------------------------------------------------
case_constraints_path_rules() {
  local name="constraints-path-rules" dir err_file rc=0 out stderr
  dir="$(line_dir)"
  err_file="$(mktemp)"
  out="$(bash "$detect_sh" "$dir" "$err_file" 2>"${dir}/err")" || rc=$?
  stderr="$(cat "${dir}/err")"
  if [ "$rc" -ne 1 ]; then
    rm -rf "$dir" "$err_file"
    fail_case "$name" "existing file: expected exit 1, got ${rc}"
    return
  fi
  assert_contains "$name" "$stderr" "${err_file} already exists" || { rm -rf "$dir" "$err_file"; return; }
  rc=0
  out="$(bash "$detect_sh" "$dir" 2>"${dir}/err")" || rc=$?
  stderr="$(cat "${dir}/err")"
  rm -rf "$dir" "$err_file"
  if [ "$rc" -ne 1 ]; then
    fail_case "$name" "one argument: expected exit 1, got ${rc}"
    return
  fi
  assert_eq "$name" "$out" "" || return
  assert_contains "$name" "$stderr" "usage: detect.sh REPO_DIR CONSTRAINTS_FILE" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# The repo's uv settings must not change what detect.sh does (issue #1003). A
# repo may set `python-downloads = "manual"` and
# `python-preference = "only-managed"` in [tool.uv] (pyproject.toml) or in
# uv.toml. uv reads those from the working directory, so the case runs
# detect.sh from inside the fixture repo, as the setup action does
# (`detect.sh .`).
#
# UV_PYTHON_INSTALL_DIR is a fresh empty dir, so no managed Python exists:
# without --no-config, uv honours the settings and fails ("Python downloads
# are set to 'manual'"). With it, uv uses a system 3.15 if there is one, else
# downloads one, as in the package images. The uv environment variables that
# would mask or change that are unset. The case needs the real uv: detect.sh
# only reads uv settings on its uv path, so without uv it fails rather than
# pass vacuously.
# ---------------------------------------------------------------------------
# run_in_configured_repo <name> <config file name> <config body>
run_in_configured_repo() {
  local name="$1" dir pydir work out stderr rc=0
  if [ -z "$real_uv" ]; then
    fail_case "$name" "uv is not on PATH; this case tests detect.sh's uv path"
    return
  fi
  dir="$(fixture '[project]
name = "vergil-python"' '[dependencies]
vergil = "v2.1"')"
  if [ "$2" = pyproject.toml ]; then
    printf '\n%s\n' "[tool.uv]" "$3" >>"${dir}/pyproject.toml"
  else
    printf '%s\n' "$3" >"${dir}/$2"
  fi
  pydir="$(mktemp -d)"
  work="$(mktemp -d)"
  : >"${work}/log"
  out="$(cd "$dir" && env -u UV_PYTHON -u UV_PYTHON_PREFERENCE \
    -u UV_PYTHON_DOWNLOADS -u UV_NO_CONFIG -u UV_CONFIG_FILE \
    PATH="${stubs}:${PATH}" STUB_LOG="${work}/log" STUB_LS_REMOTE="$ls_remote_fixture" \
    UV_PYTHON_INSTALL_DIR="$pydir" bash "$detect_sh" . "${work}/constraints.txt" 2>"${work}/err")" || rc=$?
  stderr="$(cat "${work}/err")"
  rm -rf "$dir" "$pydir" "$work"
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "detect.sh exited ${rc}: ${stderr}"
    return
  fi
  assert_eq "$name" "$out" "vergil-tooling @ git+${url}@${sha_10}" || return
  pass_case "$name"
}

uv_settings='python-downloads = "manual"
python-preference = "only-managed"'

case_ignores_pyproject_uv_settings() {
  run_in_configured_repo "ignores-pyproject-uv-settings" pyproject.toml "$uv_settings"
}

case_ignores_uv_toml() {
  run_in_configured_repo "ignores-uv-toml" uv.toml "$uv_settings"
}

# ---------------------------------------------------------------------------
# VRG_DRIVER_PYTHON unset or empty is fatal; there is no default.
# ---------------------------------------------------------------------------
case_driver_python_unset_fails() {
  local name="driver_python_unset_fails" dir err out stderr rc value
  for value in unset empty; do
    dir="$(line_dir)"
    err="$(mktemp)"
    rc=0
    if [ "$value" = unset ]; then
      out="$(env -u VRG_DRIVER_PYTHON bash "$detect_sh" "$dir" "${dir}/c.txt" 2>"$err")" || rc=$?
    else
      out="$(VRG_DRIVER_PYTHON="" bash "$detect_sh" "$dir" "${dir}/c.txt" 2>"$err")" || rc=$?
    fi
    stderr="$(cat "$err")"
    rm -rf "$dir" "$err"
    if [ "$rc" -ne 1 ]; then
      fail_case "$name" "${value}: expected exit 1, got ${rc} (stdout '${out}')"
      return
    fi
    assert_eq "$name" "$stderr" "detect.sh: VRG_DRIVER_PYTHON must be set" || return
    assert_eq "$name" "$out" "" || return
  done
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# detect.sh asks uv for the driver Python it was given. The uv stub records
# its argv and prints the ref uv would have read (STUB_UV_REF). It runs no
# Python, so the second, made-up version proves detect.sh passes on whatever
# it is given rather than a version of its own.
# ---------------------------------------------------------------------------
case_driver_python_used() {
  local name="driver_python_used" dir version
  for version in "$driver_python" 3.99; do
    dir="$(line_dir)"
    run_detect "$dir" STUB_UV_REF=v2.1 VRG_DRIVER_PYTHON="$version"
    rm -rf "$dir" "$work"
    assert_eq "$name" "$out" "vergil-tooling @ git+${url}@${sha_10}" || return
    assert_contains "$name" "$calls" "uv run --no-config --no-project --python ${version} " || return
  done
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# The action's install step, run as written.
# ---------------------------------------------------------------------------

# step_script: the `run: |` body of action.yml's "Install vergil-tooling"
# step, dedented.
step_script() {
  awk '
    /^    - name: Install vergil-tooling[[:space:]]*$/ { instep = 1; next }
    instep && /^    - / { exit }
    instep && /^      run: \|[[:space:]]*$/ { inrun = 1; next }
    inrun {
      if ($0 ~ /^        / || $0 ~ /^[[:space:]]*$/) { sub(/^        /, ""); print }
      else exit
    }
  ' "$action_yml"
}

# Step stubs, in step_stubs:
#   action/detect.sh  prints $STEP_SPEC; writes "pinned==1.0" to its second
#                     argument when $STEP_CONSTRAINED is set; logs its argv
#                     and the UV_* variables it sees.
#   bin/uv            `tool install`: logs its argv, the UV_* variables it
#                     sees and the constraints it was given; exits
#                     $STEP_INSTALL_RC; else writes vrg-package and (unless
#                     $STEP_NO_WHOAMI) vrg-whoami into $STEP_TOOL_BIN.
#                     `tool dir --bin`: prints $STEP_TOOL_BIN.
#   shadow/vrg-whoami a stale copy elsewhere on PATH (as /usr/bin would be).
# The installed vrg-whoami logs its argv and exits $STEP_WHOAMI_RC.
step_stubs="$(mktemp -d)"
trap 'rm -rf "$stubs" "$step_stubs"' EXIT
mkdir -p "${step_stubs}/action" "${step_stubs}/bin" "${step_stubs}/shadow"

cat >"${step_stubs}/action/detect.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'detect %s\n' "$*" >>"$STEP_LOG"
printf 'detect-env UV_PYTHON=%s UV_PYTHON_PREFERENCE=%s UV_NO_MANAGED_PYTHON=%s\n' \
  "${UV_PYTHON-<unset>}" "${UV_PYTHON_PREFERENCE-<unset>}" "${UV_NO_MANAGED_PYTHON-<unset>}" >>"$STEP_LOG"
[ -z "${STEP_CONSTRAINED:-}" ] || printf 'pinned==1.0\n' >"$2"
printf '%s\n' "$STEP_SPEC"
EOF

cat >"${step_stubs}/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" tool install "*)
    printf 'install %s\n' "$*" >>"$STEP_LOG"
    printf 'install-env UV_PYTHON=%s UV_PYTHON_PREFERENCE=%s UV_NO_MANAGED_PYTHON=%s\n' \
      "${UV_PYTHON-<unset>}" "${UV_PYTHON_PREFERENCE-<unset>}" "${UV_NO_MANAGED_PYTHON-<unset>}" >>"$STEP_LOG"
    prev=""
    for a in "$@"; do
      [ "$prev" != --constraints ] || printf 'install-constraints %s\n' "$(cat "$a")" >>"$STEP_LOG"
      prev="$a"
    done
    rc="${STEP_INSTALL_RC:-0}"
    [ "$rc" -eq 0 ] || { echo "uv stub: install failed" >&2; exit "$rc"; }
    mkdir -p "$STEP_TOOL_BIN"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${STEP_TOOL_BIN}/vrg-package"
    if [ -z "${STEP_NO_WHOAMI:-}" ]; then
      printf '#!/usr/bin/env bash\nprintf "whoami %%s\\n" "$*" >>"$STEP_LOG"\nexit "${STEP_WHOAMI_RC:-0}"\n' \
        >"${STEP_TOOL_BIN}/vrg-whoami"
    fi
    chmod +x "${STEP_TOOL_BIN}"/vrg-*
    ;;
  *" tool dir --bin "*) echo "$STEP_TOOL_BIN" ;;
  *)
    echo "uv stub: unexpected call: $*" >&2
    exit 97
    ;;
esac
EOF

printf '#!/usr/bin/env bash\nexit 0\n' >"${step_stubs}/shadow/vrg-whoami"
chmod +x "${step_stubs}/action/detect.sh" "${step_stubs}/bin/uv" "${step_stubs}/shadow/vrg-whoami"

# run_step [VAR=value ...]
# Runs the step script from a fresh workspace with the step stubs and the
# shadow copy first on PATH (ahead of any real vrg-whoami), and the hostile uv variables set, as a job env could.
# Sets out (stdout and stderr), rc, calls (the stub log), ghpath (the
# GITHUB_PATH file) and tool_bin; removes its temp dirs.
run_step() {
  local script ws
  script="$(step_script)"
  if [ -z "$script" ]; then
    rc=99
    out="no run script found for the Install vergil-tooling step in ${action_yml}"
    calls=""
    ghpath=""
    return
  fi
  ws="$(mktemp -d)"
  tool_bin="${ws}/home/.local/bin"
  : >"${ws}/log"
  : >"${ws}/github_path"
  rc=0
  out="$(cd "$ws" && env PATH="${step_stubs}/bin:${step_stubs}/shadow:${PATH}" \
    GITHUB_ACTION_PATH="${step_stubs}/action" GITHUB_PATH="${ws}/github_path" \
    VRG_DRIVER_PYTHON="$driver_python" STEP_LOG="${ws}/log" STEP_TOOL_BIN="$tool_bin" \
    STEP_SPEC="vergil-tooling @ git+${url}@${sha_10}" \
    UV_PYTHON=3.12 UV_PYTHON_PREFERENCE=only-system UV_NO_MANAGED_PYTHON=1 \
    "$@" bash -c "$script" 2>&1)" || rc=$?
  calls="$(cat "${ws}/log")"
  ghpath="$(cat "${ws}/github_path")"
  rm -rf "$ws"
}

# ---------------------------------------------------------------------------
# test_driver_install_line_has_managed_python_and_no_config: the install runs
# on the `python` input's version, uv-managed, with no uv config file read,
# replacing any existing install, from detect.sh's spec, constrained exactly
# when detect.sh wrote constraints.
# ---------------------------------------------------------------------------
case_step_install_line() {
  local name="test_driver_install_line_has_managed_python_and_no_config" install
  run_step STEP_CONSTRAINED=1
  [ "$rc" -eq 0 ] || { fail_case "$name" "constrained: step exited ${rc}: ${out}"; return; }
  install="$(printf '%s\n' "$calls" | grep '^install tool install ' || true)"
  assert_contains "$name" "$install" \
    "tool install --force --no-config --python ${driver_python} --managed-python --constraints " || return
  assert_contains "$name" "$install" " vergil-tooling @ git+${url}@${sha_10}" || return
  assert_contains "$name" "$calls" "install-constraints pinned==1.0" || return
  assert_contains "$name" "$calls" "detect . " || return
  run_step
  [ "$rc" -eq 0 ] || { fail_case "$name" "unconstrained: step exited ${rc}: ${out}"; return; }
  install="$(printf '%s\n' "$calls" | grep '^install tool install ' || true)"
  assert_eq "$name" "$install" \
    "install tool install --force --no-config --python ${driver_python} --managed-python vergil-tooling @ git+${url}@${sha_10}" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# test_driver_install_clears_uv_python_vars: UV_PYTHON, UV_PYTHON_PREFERENCE
# and UV_NO_MANAGED_PYTHON, set by the job, reach neither detect.sh nor the
# install.
# ---------------------------------------------------------------------------
case_step_clears_uv_vars() {
  local name="test_driver_install_clears_uv_python_vars" cleared
  cleared="UV_PYTHON=<unset> UV_PYTHON_PREFERENCE=<unset> UV_NO_MANAGED_PYTHON=<unset>"
  run_step STEP_CONSTRAINED=1
  [ "$rc" -eq 0 ] || { fail_case "$name" "step exited ${rc}: ${out}"; return; }
  assert_contains "$name" "$calls" "install-env ${cleared}" || return
  assert_contains "$name" "$calls" "detect-env ${cleared}" || return
  pass_case "$name"
}

# ---------------------------------------------------------------------------
# test_driver_install_runs_the_post_install_check: after the install,
# vrg-whoami must resolve to uv's tool bin dir and run (spec §4.3), and that
# dir goes on GITHUB_PATH. A copy elsewhere on PATH that the install did not
# replace, a vrg-whoami that does not run, or a failed install fails the step.
# ---------------------------------------------------------------------------
case_step_post_install_check() {
  local name="test_driver_install_runs_the_post_install_check"
  run_step
  [ "$rc" -eq 0 ] || { fail_case "$name" "step exited ${rc}: ${out}"; return; }
  assert_contains "$name" "$calls" "whoami --mode" || return
  assert_eq "$name" "$ghpath" "$tool_bin" || return

  run_step STEP_NO_WHOAMI=1
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "a shadowing vrg-whoami passed the check"
    return
  fi
  assert_contains "$name" "$out" \
    "::error::vrg-whoami resolves to ${step_stubs}/shadow/vrg-whoami, not ${tool_bin}/vrg-whoami" || return

  run_step STEP_WHOAMI_RC=3
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "a vrg-whoami that does not run passed the check"
    return
  fi
  assert_contains "$name" "$out" "::error::the installed vrg-whoami (${tool_bin}/vrg-whoami) does not run" || return

  run_step STEP_INSTALL_RC=2
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "a failed install passed"
    return
  fi
  assert_contains "$name" "$out" "uv stub: install failed" || return
  assert_lacks "$name" "$calls" "whoami" || return
  pass_case "$name"
}

# A case that fails has already counted itself (fail_case) and returns
# nonzero; run the rest rather than stop at the first failure.
for c in \
  case_self_repo \
  case_line_pin \
  case_exact_pin \
  case_constrained_by_commit_lock \
  case_dev_ref \
  case_missing_vergil_toml \
  case_missing_dependency \
  case_ls_remote_failure \
  case_no_tag_on_line \
  case_exact_tag_missing \
  case_fetch_failure \
  case_no_lock \
  case_export_failure \
  case_export_names_project \
  case_constraints_path_rules \
  case_ignores_pyproject_uv_settings \
  case_ignores_uv_toml \
  case_driver_python_unset_fails \
  case_driver_python_used \
  case_step_install_line \
  case_step_clears_uv_vars \
  case_step_post_install_check; do
  "$c" || true
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
