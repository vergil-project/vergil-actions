#!/usr/bin/env bash
#
# Test that the package workflows build every cell on the runtime
# `vrg-package matrix` recorded once for the release, and that cd-release
# checks the built packages against it before signing (issue #1029,
# vergil-project/vergil-tooling#3478, epic vergil-project/.github#407).
#
# Framework-free and developer-runnable: `bash package-runtime.test.sh`. CI
# runs it from .github/workflows/smoke-cd-release.yml. It needs `yq` (mikefarah
# v4, preinstalled on GitHub's ubuntu runners), `jq`, `dpkg-deb`, and a
# vergil-tooling whose `vrg-package` has `build --runtime` and `check-runtime`
# (2.1.262 or later) on PATH. No case touches the network: the python fixture
# pins [package.python].runtime, so `vrg-package matrix` never reads the
# version window.
#
# Three kinds of case:
#   * structure — cd-release.yml's package-build and ci-package.yml's build
#     take their matrix from the matrix job's `build` output, which comes from
#     `vrg-package matrix`, and pass the cell's `runtime` to `vrg-package build
#     --runtime` through an env var whose expression yields '' (never "null")
#     for a cell without one. package-sign downloads the unsigned packages and
#     the package-manifest artifact, installs rpm, and runs `vrg-package
#     check-runtime` on them before "Sign and verify rpms".
#   * runtime flow — for a python fixture, every build cell `vrg-package
#     matrix` writes carries the manifest's runtime, so the build env gets
#     it; for a staged fixture no cell has one, the env gets '', and the real
#     `vrg-package build` accepts --runtime '' but refuses --runtime null.
#   * check-runtime — the real `vrg-package check-runtime` passes .debs that
#     all depend on the recorded runtime, fails a mixed-runtime set loudly,
#     fails an empty set, and passes a manifest with no runtime.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
cd_release_yml="${repo_root}/.github/workflows/cd-release.yml"
ci_package_yml="${repo_root}/.github/workflows/ci-package.yml"

for tool in yq jq dpkg-deb vrg-package; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'package-runtime.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done

# A too-old vergil-tooling is a setup error, not a set of failing cases.
if ! vrg-package build --help | grep -q -- '--runtime'; then
  printf 'package-runtime.test.sh needs vrg-package build --runtime (vergil-tooling >= 2.1.262)\n' >&2
  exit 1
fi
if ! vrg-package check-runtime --help >/dev/null 2>&1; then
  printf 'package-runtime.test.sh needs vrg-package check-runtime (vergil-tooling >= 2.1.262)\n' >&2
  exit 1
fi

# The env expression both build steps must use.
runtime_expr="\${{ matrix.runtime || '' }}"

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

# expect <case> <what> <got> <want> — record a mismatch; returns 1 on one.
expect() {
  if [ "$3" != "$4" ]; then
    fail_case "$1" "$2: expected '$4', got '$3'"
    return 1
  fi
}

# build_case <name> <workflow> <build job> <matrix job> <resolve run> — the
# build job's matrix is the matrix job's `build` output, from its `resolve`
# step running <resolve run>, and "Build packages" passes the cell's runtime.
build_case() {
  local name="$1" wf="$2" job="$3" mjob="$4" want_resolve="$5" step run
  expect "$name" "matrix include" \
    "$(yq -r ".jobs.\"${job}\".strategy.matrix.include" "$wf")" \
    "\${{ fromJSON(needs.${mjob}.outputs.build) }}" || return 0
  expect "$name" "matrix job build output" \
    "$(yq -r ".jobs.\"${mjob}\".outputs.build" "$wf")" \
    '${{ steps.resolve.outputs.build }}' || return 0
  case "$(yq -r ".jobs.\"${mjob}\".steps[] | select(.id == \"resolve\") | .run" "$wf")" in
    *"$want_resolve"*) ;;
    *)
      fail_case "$name" "the resolve step does not run '${want_resolve}'"
      return 0
      ;;
  esac
  step="$(yq -r ".jobs.\"${job}\".steps[] | select(.name == \"Build packages\")" "$wf")"
  if [ -z "$step" ]; then
    fail_case "$name" "${job} has no 'Build packages' step"
    return 0
  fi
  expect "$name" "RUNTIME env" "$(printf '%s\n' "$step" | yq -r '.env.RUNTIME')" \
    "$runtime_expr" || return 0
  expect "$name" "CELL env" "$(printf '%s\n' "$step" | yq -r '.env.CELL')" \
    '${{ matrix.id }}' || return 0
  run="$(printf '%s\n' "$step" | yq -r '.run' | tr -d '\\\n')"
  case "$run" in
    *'vrg-package build --cell "$CELL" --runtime "$RUNTIME"'*'--version "$(vrg-version show)" --out dist/packages'*) ;;
    *)
      fail_case "$name" "the build command does not pass --runtime \"\$RUNTIME\": ${run}"
      return 0
      ;;
  esac
  pass_case "$name"
}

# The package-sign job runs check-runtime on the downloaded manifest and
# unsigned packages, after rpm is installed and before anything is signed.
case_sign_checks_runtime() {
  local name="package-sign-checks-runtime-before-signing" names idx s
  local -A at=()
  mapfile -t names < <(yq -r '.jobs."package-sign".steps[].name' "$cd_release_yml")
  for idx in "${!names[@]}"; do
    at["${names[$idx]}"]="$idx"
  done
  for s in "Checkout code" "Install vergil-tooling" "Download unsigned packages" \
    "Install rpm signing tools" "Download package manifest" \
    "Check every package's runtime" "Sign and verify rpms" "Attest package provenance"; do
    if [ -z "${at[$s]:-}" ]; then
      fail_case "$name" "package-sign has no step named '$s'"
      return 0
    fi
  done
  # Checkout empties a non-git workspace, so it must precede the download.
  if ! [ "${at["Checkout code"]}" -lt "${at["Download unsigned packages"]}" ] ||
    ! [ "${at["Install vergil-tooling"]}" -lt "${at["Check every package's runtime"]}" ] ||
    ! [ "${at["Download unsigned packages"]}" -lt "${at["Check every package's runtime"]}" ] ||
    ! [ "${at["Install rpm signing tools"]}" -lt "${at["Check every package's runtime"]}" ] ||
    ! [ "${at["Download package manifest"]}" -lt "${at["Check every package's runtime"]}" ] ||
    ! [ "${at["Check every package's runtime"]}" -lt "${at["Sign and verify rpms"]}" ]; then
    fail_case "$name" "package-sign steps are out of order: ${names[*]}"
    return 0
  fi
  q() { yq -r ".jobs.\"package-sign\".steps[] | select(.name == \"$1\") | $2" "$cd_release_yml"; }
  expect "$name" "checkout" "$(q "Checkout code" .uses)" "actions/checkout@v6" || return 0
  expect "$name" "setup" "$(q "Install vergil-tooling" .uses)" \
    "./actions/shared/setup/vergil" || return 0
  expect "$name" "unsigned path" "$(q "Download unsigned packages" .with.path)" \
    "dist/packages" || return 0
  case "$(q "Install rpm signing tools" .run)" in
    *"install -y --no-install-recommends rpm "*) ;;
    *)
      fail_case "$name" "Install rpm signing tools does not install rpm"
      return 0
      ;;
  esac
  expect "$name" "manifest artifact" "$(q "Download package manifest" .with.name)" \
    "package-manifest" || return 0
  expect "$name" "manifest path" "$(q "Download package manifest" .with.path)" "." || return 0
  # The artifact package-matrix uploads under that name is that file.
  expect "$name" "uploaded manifest" \
    "$(yq -r '.jobs."package-matrix".steps[] | select(.with.name == "package-manifest") | .with.path' \
      "$cd_release_yml")" "packages-manifest.json" || return 0
  case "$(q "Check every package's runtime" .run)" in
    *"vrg-package check-runtime --manifest packages-manifest.json --artifacts dist/packages"*) ;;
    *)
      fail_case "$name" "the check step does not run vrg-package check-runtime on the manifest and dist/packages"
      return 0
      ;;
  esac
  pass_case "$name"
}

# Fixtures.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fixture <dir> <[package] lines> — a minimal repo vrg-package matrix accepts.
fixture() {
  mkdir -p "$1"
  {
    printf '[project]\nrepository-type = "library"\nversioning-scheme = "semver"\n'
    printf 'branching-model = "library-release"\nrelease-model = "tagged-release"\n'
    printf '\n[ci]\nintegration-tests = false\n\n[dependencies]\nvergil = "v2.1"\n\n'
    printf '[package]\nvendor = "vergil"\nsummary = "Fixture"\nsmoke = "true"\n%s\n' "$2"
  } >"$1/vergil.toml"
}

py="${work}/python"
fixture "$py" "$(printf 'builder = "python"\n\n[package.python]\nruntime = "3.14.8"')"
printf '[project]\nname = "fixture-tool"\nversion = "1.0.0"\n' >"${py}/pyproject.toml"
: >"${py}/uv.lock"

staged="${work}/staged"
fixture "$staged" "$(printf 'builder = "staged"\nname = "fixture-staged"\n\n[package.staged]\nbuild-command = "true"')"

# matrix_build <repo> <manifest> — the `build` output `vrg-package matrix
# --github-output --manifest <manifest>` writes, as the workflows run it.
matrix_build() {
  local o rc=0
  o="${work}/github-output"
  : >"$o"
  (cd "$1" && GITHUB_OUTPUT="$o" vrg-package matrix --github-output --manifest "$2") \
    >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  sed -n 's/^build=//p' "$o"
}

# render_runtime <cell json> — the RUNTIME env value for one cell: the
# `matrix.runtime || ''` expression, which is '' when the key is absent.
render_runtime() {
  printf '%s' "$1" | jq -r '.runtime // ""'
}

case_python_cells_carry_runtime() {
  local name="python-cells-build-on-the-recorded-runtime" build recorded cell got n=0
  if ! build="$(matrix_build "$py" "${work}/python-manifest.json")"; then
    fail_case "$name" "vrg-package matrix failed for the python fixture"
    return 0
  fi
  recorded="$(jq -r '.runtime // "ABSENT"' "${work}/python-manifest.json")"
  expect "$name" "manifest runtime" "$recorded" "3.14.8" || return 0
  while IFS= read -r cell; do
    n=$((n + 1))
    got="$(render_runtime "$cell")"
    expect "$name" "$(printf '%s' "$cell" | jq -r .id) RUNTIME" "$got" "$recorded" || return 0
  done < <(printf '%s' "$build" | jq -c '.[]')
  if [ "$n" -lt 2 ]; then
    fail_case "$name" "expected at least two build cells, got ${n}"
    return 0
  fi
  pass_case "$name"
}

case_staged_cells_get_empty_runtime() {
  local name="staged-cells-get-an-empty-runtime" build cell got err rc n=0
  if ! build="$(matrix_build "$staged" "${work}/staged-manifest.json")"; then
    fail_case "$name" "vrg-package matrix failed for the staged fixture"
    return 0
  fi
  expect "$name" "manifest runtime" \
    "$(jq -r 'has("runtime")' "${work}/staged-manifest.json")" "false" || return 0
  while IFS= read -r cell; do
    n=$((n + 1))
    expect "$name" "cell has runtime" "$(printf '%s' "$cell" | jq -r 'has("runtime")')" \
      "false" || return 0
    got="$(render_runtime "$cell")"
    expect "$name" "RUNTIME" "$got" "" || return 0
  done < <(printf '%s' "$build" | jq -c '.[]')
  if [ "$n" -lt 1 ]; then
    fail_case "$name" "no build cells for the staged fixture"
    return 0
  fi
  # The real tool: a literal "null" is a runtime a staged build refuses;
  # '' passes the runtime gate (the fixture then fails later, on its empty
  # staging root, which is not what this case checks).
  rc=0
  err="$(cd "$staged" && vrg-package build --cell shared-amd64 --runtime null \
    --version 1.0.0 --out "${work}/out" --staging "${work}/stage" 2>&1)" || rc=$?
  case "$rc:$err" in
    0:*)
      fail_case "$name" "vrg-package build accepted --runtime null for a staged builder"
      return 0
      ;;
    *"--runtime applies only to builder"*) ;;
    *)
      fail_case "$name" "--runtime null failed for another reason: ${err}"
      return 0
      ;;
  esac
  rc=0
  err="$(cd "$staged" && vrg-package build --cell shared-amd64 --runtime "" \
    --version 1.0.0 --out "${work}/out" --staging "${work}/stage" 2>&1)" || rc=$?
  case "$err" in
    *"--runtime"*)
      fail_case "$name" "vrg-package build refused --runtime '': ${err}"
      return 0
      ;;
  esac
  pass_case "$name"
}

# deb <path> <arch> <Depends> — a minimal .deb with that dependency line.
deb() {
  local root
  root="$(mktemp -d "${work}/deb.XXXXXX")"
  mkdir -p "${root}/DEBIAN"
  printf 'Package: fixture-tool\nVersion: 1.0.0-1\nArchitecture: %s\nMaintainer: Fixture <fixture@example.com>\nDescription: fixture\nDepends: %s\n' \
    "$2" "$3" >"${root}/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$root" "$1" >/dev/null
  rm -rf "$root"
}

# check_case <name> <manifest> <artifacts> <want rc 0|1> <want output>
check_case() {
  local name="$1" out rc=0
  out="$(vrg-package check-runtime --manifest "$2" --artifacts "$3" 2>&1)" || rc=$?
  if [ "$4" -eq 0 ] && [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected check-runtime to pass, it failed (exit ${rc}): ${out}"
    return 0
  fi
  if [ "$4" -ne 0 ] && [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected check-runtime to fail, it passed: ${out}"
    return 0
  fi
  case "$out" in
    *"$5"*) ;;
    *)
      fail_case "$name" "expected output containing '$5', got: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

same="${work}/same"
mixed="${work}/mixed"
empty="${work}/empty"
mkdir -p "$same" "$mixed" "$empty"
deb "${same}/fixture-tool_1.0.0-1_amd64.deb" amd64 'vergil-python3.14 (>= 3.14.8+20261001), libc6'
deb "${same}/fixture-tool_1.0.0-1_arm64.deb" arm64 'vergil-python3.14 (>= 3.14.8+20261001)'
deb "${mixed}/fixture-tool_1.0.0-1_amd64.deb" amd64 'vergil-python3.15 (>= 3.15.1+20261021)'
deb "${mixed}/fixture-tool_1.0.0-1_arm64.deb" arm64 'vergil-python3.14 (>= 3.14.8+20261001)'

build_case "cd-release-package-build-passes-runtime" "$cd_release_yml" \
  package-build package-matrix \
  "vrg-package matrix --github-output --manifest packages-manifest.json"
build_case "ci-package-build-passes-runtime" "$ci_package_yml" \
  build matrix 'vrg-package matrix --github-output --tier "$TIER"'
case_sign_checks_runtime
case_python_cells_carry_runtime
case_staged_cells_get_empty_runtime
# The manifests come from the real `vrg-package matrix` runs above.
if [ -f "${work}/python-manifest.json" ]; then
  check_case "check-runtime-passes-one-runtime" "${work}/python-manifest.json" "$same" 0 \
    "depend on vergil-python3.14"
  check_case "check-runtime-fails-mixed-runtimes" "${work}/python-manifest.json" "$mixed" 1 \
    "depends on vergil-python3.15"
  check_case "check-runtime-fails-no-packages" "${work}/python-manifest.json" "$empty" 1 \
    "no packages to check"
else
  fail_case "check-runtime-cases" "no python manifest from vrg-package matrix"
fi
if [ -f "${work}/staged-manifest.json" ]; then
  check_case "check-runtime-passes-without-a-runtime" "${work}/staged-manifest.json" "$mixed" 0 \
    "records no runtime"
else
  fail_case "check-runtime-without-runtime" "no staged manifest from vrg-package matrix"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
