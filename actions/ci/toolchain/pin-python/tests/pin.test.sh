#!/usr/bin/env bash
#
# Behavioural test for pin.sh — the step that pins uv to a CI leg's Python
# interpreter — plus structural checks that every Python matrix leg in the
# CI workflows pins through it, and that every uv command a workflow job or
# composite action runs for a Python repo pins the interpreter source with
# UV_PYTHON_PREFERENCE=only-system (issue #1002). Fixture workflows and actions
# test that source guard both ways.
#
# Framework-free and developer-runnable: `bash pin.test.sh`. Each pin.sh case
# runs pin.sh against a scratch GITHUB_ENV file and asserts the exit status,
# the annotation and the file's contents.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin_sh="${here}/../pin.sh"
workflows="${here}/../../../../../.github/workflows"
actions="${here}/../../../.."

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
stderr=""
env_out=""

# run_pin <version> [<existing GITHUB_ENV contents>]
run_pin() {
  local env_file se
  env_file="$(mktemp)"
  se="$(mktemp)"
  printf '%s' "${2:-}" >"$env_file"
  rc=0
  VERSION="$1" GITHUB_ENV="$env_file" bash "$pin_sh" >/dev/null 2>"$se" || rc=$?
  stderr="$(cat "$se")"
  env_out="$(cat "$env_file")"
  rm -f "$env_file" "$se"
}

# assert_fail <name> <substring of the ::error:: annotation>
assert_fail() {
  if [ "$rc" -eq 0 ]; then
    fail_case "$1" "expected a non-zero exit, got 0"
    return 1
  fi
  case "$stderr" in
    *"::error::$2"*) return 0 ;;
  esac
  fail_case "$1" "expected '::error::$2', got '$stderr'"
  return 1
}

case_pins_version_and_source() {
  local name="pins-version-and-system-source"
  run_pin 3.14
  if [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; stderr: ${stderr}"
    return 0
  fi
  local want
  want="$(printf 'UV_PYTHON=3.14\nUV_PYTHON_PREFERENCE=only-system')"
  if [ "$env_out" != "$want" ]; then
    fail_case "$name" "expected GITHUB_ENV '${want}', got '${env_out}'"
    return 0
  fi
  pass_case "$name"
}

case_appends() {
  local name="appends-to-existing-github-env"
  run_pin 3.12 $'EARLIER=1\n'
  local want
  want="$(printf 'EARLIER=1\nUV_PYTHON=3.12\nUV_PYTHON_PREFERENCE=only-system')"
  if [ "$rc" -ne 0 ] || [ "$env_out" != "$want" ]; then
    fail_case "$name" "rc=${rc}; expected '${want}', got '${env_out}'"
    return 0
  fi
  pass_case "$name"
}

case_bad_version() {
  local name="version-not-x-y"
  for v in "" latest 3 3.14.1 "3.14 "; do
    run_pin "$v"
    assert_fail "$name ('$v')" "pin-python: version must be an x.y" || return 0
    if [ -n "$env_out" ]; then
      fail_case "$name ('$v')" "wrote to GITHUB_ENV on error: '${env_out}'"
      return 0
    fi
  done
  pass_case "$name"
}

case_no_github_env() {
  local name="github-env-unset"
  rc=0
  stderr="$(VERSION=3.14 GITHUB_ENV="" bash "$pin_sh" 2>&1 >/dev/null)" || rc=$?
  assert_fail "$name" "pin-python: GITHUB_ENV is not set" || return 0
  pass_case "$name"
}

# Every job that runs the Python toolchain assertion must pin through this
# action first, and no workflow may set UV_PYTHON by hand (which would skip
# UV_PYTHON_PREFERENCE=only-system).
case_workflows_pin_every_python_leg() {
  local name="workflows-pin-every-python-leg"
  local wf asserts pins legs=0
  for wf in "$workflows"/*.yml; do
    if grep -q 'UV_PYTHON=' "$wf"; then
      fail_case "$name" "$(basename "$wf") sets UV_PYTHON by hand; use ./actions/ci/toolchain/pin-python"
      return 0
    fi
    asserts="$(grep -c 'uses: ./actions/ci/toolchain/assert$' "$wf" || true)"
    pins="$(grep -c 'uses: ./actions/ci/toolchain/pin-python$' "$wf" || true)"
    if [ "$asserts" != "$pins" ]; then
      fail_case "$name" "$(basename "$wf") has ${asserts} assert-toolchain step(s) but ${pins} pin-python step(s)"
      return 0
    fi
    legs=$((legs + pins))
  done
  # ci-quality lint + typecheck + custom, ci-audit dependencies, ci-test unit.
  if [ "$legs" -ne 5 ]; then
    fail_case "$name" "expected 5 pinned Python legs, found ${legs}"
    return 0
  fi
  pass_case "$name"
}

# --- uv source guard (issue #1002) -------------------------------------------
#
# A uv command that resolves a Python against the repo's project honours the
# repo's uv settings, so a repo with `python-preference = "only-managed"` can
# make it download a managed interpreter (or, with `python-downloads =
# "manual"`, fail). Every such command must run with
# UV_PYTHON_PREFERENCE=only-system. `uv tool ...` is not matched: uv tool
# commands ignore a project's uv settings and install vergil-tooling only.
#
# A backtick before `uv` marks prose (a description or doc string), not a
# command: shell code uses $(...), never backticks.
#
# uv takes global options before its subcommand (issue #1009): `uv --quiet run`,
# `uv -q sync`, `uv --directory d run`. uv_global_opts_re matches any run of
# them — each an option token, optionally followed by one value token that does
# not start with `-`. Only a subcommand in the list ends the run, so `uv tool`,
# `uv --version` and `uv -q tool run` still do not match.
uv_cmd_start_re='(^|[^[:alnum:]_.`-])uv'
uv_global_opts_re='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
uv_subcmd_re='(run|sync|lock|pip|venv|build|publish|export|add|remove|tree|python)'
uv_cmd_re="${uv_cmd_start_re}${uv_global_opts_re}[[:space:]]+${uv_subcmd_re}"'([[:space:]"]|$)'

# Actions whose uv commands are pinned by their caller, not in the action.
# The workflow check below treats a job that uses one as running uv.
#   ci/toolchain/assert — runs after ./actions/ci/toolchain/pin-python.
caller_pinned_actions='ci/toolchain/assert/'

# Files that run uv without the pin, each with its reason. Every uv command in
# them must instead pass --no-config on the same line, so the repo's uv
# settings cannot reach it at all (issue #1003).
#   package/setup/detect.sh — reads vergil.toml with `uv run --no-config
#     --no-project --python 3.14` in raw package-build images that ship no
#     Python, so it needs uv's managed interpreter; it never runs the repo's
#     code. Without --no-config a repo's python-downloads = "manual" breaks it.
config_free_files='package/setup/detect.sh'

# The config-ignoring form: --no-config among uv's options, so it is uv's flag
# and never an argument of the command uv runs. Either among the global options
# before the subcommand (`uv --no-config run ...`, `uv -q --directory d
# --no-config run ...`), or among the flags right after it (`uv run --no-config
# ...`, `uv -q run --no-project --no-config ...`). After the subcommand only
# bare flags may precede it: a non-flag token there may be the command uv runs,
# and --no-config after it would be that command's argument.
uv_no_config_re="${uv_cmd_start_re}("
uv_no_config_re+="${uv_global_opts_re}[[:space:]]+--no-config${uv_global_opts_re}[[:space:]]+${uv_subcmd_re}"
uv_no_config_re+="|${uv_global_opts_re}[[:space:]]+${uv_subcmd_re}([[:space:]]+-[^[:space:]]+)*[[:space:]]+--no-config"
uv_no_config_re+=')([[:space:]]|$)'

# check_workflow_uv_pins <workflows dir>
#
# Prints "<file>: job <job> ..." for every job that runs uv before it pins the
# source. A job pins with a job-level `env: UV_PYTHON_PREFERENCE: only-system`
# or a `./actions/ci/toolchain/pin-python` step; it runs uv with a uv command
# (uv_cmd_re) in a non-comment line or a step that uses a caller-pinned action.
check_workflow_uv_pins() {
  local wf
  for wf in "$1"/*.yml; do
    [ -e "$wf" ] || continue
    awk -v re="$uv_cmd_re" -v file="$(basename "$wf")" '
      function indent(s) { match(s, /^ */); return RLENGTH }
      function use(what) {
        if (!pinned && !reported) {
          printf "%s: job %s runs uv (%s) before pinning UV_PYTHON_PREFERENCE=only-system\n", file, job, what
          reported = 1
        }
      }
      /^jobs:[[:space:]]*$/ { injobs = 1; next }
      !injobs { next }
      /^[^[:space:]#]/ { injobs = 0; job = ""; next }
      /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
        job = $1; sub(/:$/, "", job)
        pinned = 0; reported = 0; injobenv = 0
        next
      }
      job == "" { next }
      {
        stripped = $0
        sub(/^[[:space:]]+/, "", stripped)
      }
      stripped == "" || stripped ~ /^#/ { next }
      injobenv && indent($0) <= 4 { injobenv = 0 }
      injobenv {
        if (indent($0) == 6 && stripped ~ /^UV_PYTHON_PREFERENCE:[[:space:]]*only-system[[:space:]]*$/) pinned = 1
        next
      }
      /^    env:[[:space:]]*$/ { injobenv = 1; next }
      stripped ~ /uses:[[:space:]]+\.\/actions\/ci\/toolchain\/pin-python[[:space:]]*$/ { pinned = 1; next }
      stripped ~ /uses:[[:space:]]+\.\/actions\/ci\/toolchain\/assert[[:space:]]*$/ { use("ci/toolchain/assert"); next }
      $0 ~ re { use(stripped) }
    ' "$wf"
  done
}

# check_action_uv_pins <actions dir>
#
# Prints "<path>:<line>: ..." for every uv command in a composite action or
# script (tests excluded) that is not pinned: inline
# (UV_PYTHON_PREFERENCE=only-system on the same line), by a step env
# (`UV_PYTHON_PREFERENCE: only-system` in the same action.yml) or by the caller
# (caller_pinned_actions). In a config-free file (config_free_files) the pin
# does not count: every uv command must pass --no-config instead.
check_action_uv_pins() {
  local root="$1" f rel prefix skip config_free
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    skip=0
    for prefix in $caller_pinned_actions; do
      case "$rel" in "$prefix"*) skip=1 ;; esac
    done
    [ "$skip" -eq 0 ] || continue
    config_free=0
    for prefix in $config_free_files; do
      [ "$rel" != "$prefix" ] || config_free=1
    done
    if [ "$config_free" -eq 1 ]; then
      awk -v re="$uv_cmd_re" -v ok="$uv_no_config_re" -v file="$rel" '
        {
          stripped = $0
          sub(/^[[:space:]]+/, "", stripped)
        }
        stripped ~ /^#/ { next }
        $0 ~ re && $0 !~ ok {
          printf "%s:%d: uv runs without --no-config in a config-free file: %s\n", file, NR, stripped
        }
      ' "$f"
      continue
    fi
    if grep -Eq '^[[:space:]]*UV_PYTHON_PREFERENCE:[[:space:]]*only-system[[:space:]]*$' "$f"; then
      continue
    fi
    awk -v re="$uv_cmd_re" -v file="$rel" '
      {
        stripped = $0
        sub(/^[[:space:]]+/, "", stripped)
      }
      stripped ~ /^#/ { next }
      $0 ~ re && $0 !~ /UV_PYTHON_PREFERENCE=only-system/ {
        printf "%s:%d: uv runs without UV_PYTHON_PREFERENCE=only-system: %s\n", file, NR, stripped
      }
    ' "$f"
  done < <(find "$root" -path '*/tests' -prune -o -type f \( -name 'action.yml' -o -name '*.sh' \) -print | sort)
}

# The real workflows and actions: every uv command for a Python repo pins its
# interpreter source.
case_repo_pins_uv_source() {
  local name="repo-pins-uv-source-everywhere" out
  out="$(check_workflow_uv_pins "$workflows"; check_action_uv_pins "$actions")"
  if [ -n "$out" ]; then
    fail_case "$name" "$out"
    return 0
  fi
  pass_case "$name"
}

# The docs jobs, which resolve no version, pin the source with a job-level env.
case_docs_jobs_pin_source() {
  local name="docs-jobs-pin-source" wf
  for wf in ci-docs.yml cd-docs.yml; do
    if ! grep -Eq '^      UV_PYTHON_PREFERENCE: only-system$' "${workflows}/${wf}"; then
      fail_case "$name" "${wf} has no job-level UV_PYTHON_PREFERENCE: only-system"
      return 0
    fi
  done
  pass_case "$name"
}

# Fixtures: the guard catches what it should, and only that.
scratch=""
make_scratch() {
  scratch="$(mktemp -d)"
  mkdir -p "${scratch}/workflows" "${scratch}/actions"
}

# expect_guard <case name> <want: pass|fail> <workflow yaml> [<action path> <action body>]
expect_guard() {
  local name="$1" want="$2" out
  make_scratch
  printf '%s\n' "$3" >"${scratch}/workflows/fixture.yml"
  if [ $# -ge 5 ]; then
    mkdir -p "$(dirname "${scratch}/actions/$4")"
    printf '%s\n' "$5" >"${scratch}/actions/$4"
  fi
  out="$(check_workflow_uv_pins "${scratch}/workflows"; check_action_uv_pins "${scratch}/actions")"
  rm -rf "$scratch"
  if [ "$want" = pass ] && [ -n "$out" ]; then
    fail_case "$name" "expected the guard to pass, it reported: ${out}"
  elif [ "$want" = fail ] && [ -z "$out" ]; then
    fail_case "$name" "expected the guard to report an unpinned uv, it passed"
  else
    pass_case "$name"
  fi
}

case_guard_fixtures() {
  local unpinned job_env pin_step step_env_only late_pin assert_unpinned other_job
  unpinned='name: F
on: push
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - run: uv run mkdocs build'
  job_env='name: F
on: push
jobs:
  docs:
    runs-on: ubuntu-latest
    env:
      UV_PYTHON_PREFERENCE: only-system
    steps:
      - run: echo "cmd=uv run mkdocs" >> "$GITHUB_OUTPUT"'
  pin_step='name: F
on: push
jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/ci/toolchain/pin-python
        with:
          version: "3.14"
      - run: uv sync --group dev --frozen
      - uses: ./actions/ci/toolchain/assert'
  step_env_only='name: F
on: push
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        env:
          UV_PYTHON_PREFERENCE: only-system
        run: uv run mkdocs build'
  late_pin='name: F
on: push
jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - run: uv sync --group dev --frozen
      - uses: ./actions/ci/toolchain/pin-python'
  assert_unpinned='name: F
on: push
jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/ci/toolchain/assert'
  other_job='name: F
on: push
jobs:
  docs:
    runs-on: ubuntu-latest
    env:
      UV_PYTHON_PREFERENCE: only-system
    steps:
      - run: uv run mkdocs build
  deploy:
    runs-on: ubuntu-latest
    steps:
      # uv run mike would be fine in a comment
      - run: uv run mike deploy'

  expect_guard "guard-fails-unpinned-uv-run" fail "$unpinned"
  expect_guard "guard-passes-job-env-pin" pass "$job_env"
  expect_guard "guard-passes-pin-python-step" pass "$pin_step"
  expect_guard "guard-fails-step-env-only" fail "$step_env_only"
  expect_guard "guard-fails-pin-after-uv" fail "$late_pin"
  expect_guard "guard-fails-assert-without-pin" fail "$assert_unpinned"
  expect_guard "guard-pin-is-per-job" fail "$other_job"
  expect_guard "guard-passes-uv-tool-install" pass \
    "$(printf 'name: F\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: uv tool install vergil-tooling')"

  local wf_ok
  wf_ok="$(printf 'name: F\non: push\njobs: {}')"
  expect_guard "guard-fails-unpinned-action" fail "$wf_ok" \
    "x/run/action.yml" "$(printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: uv run mike deploy')"
  expect_guard "guard-fails-unpinned-script" fail "$wf_ok" \
    "x/run/go.sh" "$(printf '#!/usr/bin/env bash\nuv sync --frozen')"
  expect_guard "guard-passes-action-step-env" pass "$wf_ok" \
    "x/run/action.yml" "$(printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      env:\n        UV_PYTHON_PREFERENCE: only-system\n      run: uv run mike deploy')"
  expect_guard "guard-passes-inline-pin" pass "$wf_ok" \
    "x/run/go.sh" "$(printf '#!/usr/bin/env bash\nUV_PYTHON_PREFERENCE=only-system uv sync --frozen')"
  expect_guard "guard-ignores-comments-and-prose" pass "$wf_ok" \
    "x/run/action.yml" "$(printf 'description: runs `uv sync` for you\nruns:\n  using: composite\n  steps:\n    # uv run mike here is a comment\n    - shell: bash\n      run: uv tool install x')"
  expect_guard "guard-skips-action-tests" pass "$wf_ok" \
    "x/run/tests/t.sh" "$(printf '#!/usr/bin/env bash\nuv run pytest')"

  # Config-free files (issue #1003): detect.sh must use the config-ignoring
  # form, and the source pin is no substitute for it.
  local detect='package/setup/detect.sh'
  expect_guard "guard-passes-config-free-no-config" pass "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nref="$(uv run --no-config --no-project --python 3.14 python -c "$x")"')"
  expect_guard "guard-passes-config-free-global-no-config" pass "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv --no-config run --no-project --python 3.14 python -c pass')"
  expect_guard "guard-fails-config-free-without-no-config" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nref="$(uv run --no-project --python 3.14 python -c "$x")"')"
  expect_guard "guard-fails-config-free-pin-instead" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nUV_PYTHON_PREFERENCE=only-system uv run --no-project --python 3.14 python')"
  expect_guard "guard-fails-config-free-step-env-instead" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\n# env:\n  UV_PYTHON_PREFERENCE: only-system\nuv run --no-project python')"
  expect_guard "guard-fails-config-free-no-config-as-argument" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv run --no-project python tool.py --no-config')"
  expect_guard "guard-fails-config-free-second-uv-unflagged" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv run --no-config --no-project python -c pass\nuv sync --frozen')"
  # The no-config form does not exempt any other file from the source pin.
  expect_guard "guard-fails-no-config-outside-config-free-files" fail "$wf_ok" \
    "x/run/go.sh" "$(printf '#!/usr/bin/env bash\nuv run --no-config --no-project python -c pass')"

  # Global options before the subcommand (issue #1009) do not hide a uv command.
  local wf_head='name: F\non: push\njobs:\n  docs:\n    runs-on: ubuntu-latest\n'
  # shellcheck disable=SC2059 # wf_head is a printf format by design.
  expect_guard "guard-fails-unpinned-uv-quiet-run" fail \
    "$(printf "${wf_head}"'    steps:\n      - run: uv --quiet run mkdocs build')"
  # shellcheck disable=SC2059
  expect_guard "guard-passes-job-env-pin-uv-quiet-run" pass \
    "$(printf "${wf_head}"'    env:\n      UV_PYTHON_PREFERENCE: only-system\n    steps:\n      - run: uv --quiet run mkdocs build')"
  expect_guard "guard-fails-unpinned-uv-q-sync" fail "$wf_ok" \
    "x/run/go.sh" "$(printf '#!/usr/bin/env bash\nuv -q sync --frozen')"
  expect_guard "guard-passes-inline-pin-uv-q-sync" pass "$wf_ok" \
    "x/run/go.sh" "$(printf '#!/usr/bin/env bash\nUV_PYTHON_PREFERENCE=only-system uv -q sync --frozen')"
  expect_guard "guard-fails-unpinned-uv-directory-run" fail "$wf_ok" \
    "x/run/action.yml" "$(printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: uv --directory d run pytest')"
  expect_guard "guard-passes-step-env-uv-directory-run" pass "$wf_ok" \
    "x/run/action.yml" "$(printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      env:\n        UV_PYTHON_PREFERENCE: only-system\n      run: uv --directory d run pytest')"
  expect_guard "guard-passes-uv-global-opts-exempt-forms" pass "$wf_ok" \
    "x/run/go.sh" "$(printf '#!/usr/bin/env bash\n# uv --quiet run mike here is a comment\necho "runs `uv -q sync` for you"\nuv --version\nuv -q tool install x\nuv --directory d tool run ruff')"

  expect_guard "guard-fails-config-free-uv-q-run-without-no-config" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv -q run --no-project --python 3.14 python -c pass')"
  expect_guard "guard-fails-config-free-uv-directory-run-without-no-config" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv --directory d run --no-project python -c pass')"
  expect_guard "guard-fails-config-free-uv-q-no-config-as-argument" fail "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv -q run --no-project python tool.py --no-config')"
  expect_guard "guard-passes-config-free-uv-q-run-no-config" pass "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv -q run --no-config --no-project python -c pass')"
  expect_guard "guard-passes-config-free-no-config-among-globals" pass "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv -q --directory d --no-config run --no-project python -c pass')"
  expect_guard "guard-passes-config-free-no-config-after-flags" pass "$wf_ok" \
    "$detect" "$(printf '#!/usr/bin/env bash\nuv --quiet run --no-project --no-config python -c pass')"
}

case_pins_version_and_source
case_appends
case_bad_version
case_no_github_env
case_workflows_pin_every_python_leg
case_repo_pins_uv_source
case_docs_jobs_pin_source
case_guard_fixtures

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
