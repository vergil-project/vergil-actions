#!/usr/bin/env bash
#
# Behavioural test for publish.sh — the registry-publish action's Publish step
# core — plus a static check of the credential wiring from the cd-release
# secrets, through the action inputs, to the env vars the publish tools read
# (issue #980).
#
# Framework-free and developer-runnable: `bash publish.test.sh`. CI runs it
# from .github/workflows/smoke-registry-publish.yml.
#
# Each publish.sh case runs the script with a controlled environment and a
# PUBLISH_CMD that touches a marker file, then asserts the exit code, the
# output and whether the publish command ran.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_dir="${here}/.."
publish_sh="${action_dir}/publish.sh"
repo_root="$(cd "${action_dir}/../../../.." && pwd)"
action_yml="${action_dir}/action.yml"
cd_release_yml="${repo_root}/.github/workflows/cd-release.yml"

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

# run_publish <marker> <env assignments...> — run publish.sh under `env -i`
# (so no credential leaks in from the caller) with PUBLISH_CMD touching
# <marker>. Sets the globals out and rc.
run_publish() {
  local marker="$1"
  shift
  set +e
  out="$(env -i PATH="${PATH}" PUBLISH_CMD="touch '${marker}'" "$@" \
    bash "${publish_sh}" 2>&1)"
  rc=$?
  set -e
}

# expect_published <name> <env assignments...> — publish.sh exits 0 and runs
# the publish command.
expect_published() {
  local name="$1"
  shift
  local dir marker
  dir="$(mktemp -d)"
  marker="${dir}/published"
  run_publish "${marker}" "$@"
  if [ "${rc}" -ne 0 ]; then
    rm -rf "${dir}"
    fail_case "${name}" "expected exit 0, got ${rc}; output: ${out}"
    return
  fi
  if [ ! -e "${marker}" ]; then
    rm -rf "${dir}"
    fail_case "${name}" "publish command did not run; output: ${out}"
    return
  fi
  rm -rf "${dir}"
  pass_case "${name}"
}

# expect_refused <name> <pattern> <env assignments...> — publish.sh exits
# non-zero with an ::error:: matching <pattern> and never runs the publish
# command.
expect_refused() {
  local name="$1" pattern="$2"
  shift 2
  local dir marker
  dir="$(mktemp -d)"
  marker="${dir}/published"
  run_publish "${marker}" "$@"
  if [ "${rc}" -eq 0 ]; then
    rm -rf "${dir}"
    fail_case "${name}" "expected non-zero exit, got 0; output: ${out}"
    return
  fi
  if [ -e "${marker}" ]; then
    rm -rf "${dir}"
    fail_case "${name}" "publish command ran despite the refusal; output: ${out}"
    return
  fi
  if ! printf '%s\n' "${out}" | grep -q "^::error::.*${pattern}"; then
    rm -rf "${dir}"
    fail_case "${name}" "expected an ::error:: matching '${pattern}'; output: ${out}"
    return
  fi
  rm -rf "${dir}"
  pass_case "${name}"
}

# ---------------------------------------------------------------------------
# Rust: cargo publish reads CARGO_REGISTRY_TOKEN.
# ---------------------------------------------------------------------------
expect_published "rust-token-set-publishes" \
  CREDENTIAL_SECRET=CARGO_REGISTRY_TOKEN CARGO_REGISTRY_TOKEN=tok

expect_refused "rust-token-missing-fails" \
  "CARGO_REGISTRY_TOKEN.*CARGO_REGISTRY_TOKEN secret" \
  CREDENTIAL_SECRET=CARGO_REGISTRY_TOKEN CARGO_REGISTRY_TOKEN=

expect_refused "rust-token-unset-fails" \
  "CARGO_REGISTRY_TOKEN.*CARGO_REGISTRY_TOKEN secret" \
  CREDENTIAL_SECRET=CARGO_REGISTRY_TOKEN

# ---------------------------------------------------------------------------
# Java: maven-gpg-plugin reads MAVEN_GPG_PASSPHRASE, fed by GPG_PASSPHRASE.
# ---------------------------------------------------------------------------
expect_published "java-passphrase-set-publishes" \
  CREDENTIAL_SECRET=MAVEN_GPG_PASSPHRASE MAVEN_GPG_PASSPHRASE=pass

expect_refused "java-passphrase-missing-fails" \
  "MAVEN_GPG_PASSPHRASE.*GPG_PASSPHRASE secret" \
  CREDENTIAL_SECRET=MAVEN_GPG_PASSPHRASE MAVEN_GPG_PASSPHRASE=

# ---------------------------------------------------------------------------
# No credential named (e.g. Python via PyPI trusted publishing, or a
# publish-command override for a language with no credential): publish runs and
# the tool itself authenticates or fails.
# ---------------------------------------------------------------------------
expect_published "no-credential-named-publishes" CREDENTIAL_SECRET=

# ---------------------------------------------------------------------------
# A credential name the action does not provide (vergil-tooling and
# vergil-actions disagree): refuse loudly, even when a variable of that name
# happens to be set, because the publish tool would not read it.
# ---------------------------------------------------------------------------
expect_refused "unmapped-pypi-token-fails" \
  "PYPI_TOKEN.*does not provide" \
  CREDENTIAL_SECRET=PYPI_TOKEN PYPI_TOKEN=tok

expect_refused "unmapped-crates-io-token-fails" \
  "CRATES_IO_TOKEN.*does not provide" \
  CREDENTIAL_SECRET=CRATES_IO_TOKEN CRATES_IO_TOKEN=tok

# ---------------------------------------------------------------------------
# A failing publish command fails the step.
# ---------------------------------------------------------------------------
case_publish_failure_propagates() {
  local name="publish-failure-propagates"
  set +e
  out="$(env -i PATH="${PATH}" PUBLISH_CMD="exit 7" CREDENTIAL_SECRET= \
    bash "${publish_sh}" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -ne 7 ]; then
    fail_case "${name}" "expected exit 7, got ${rc}; output: ${out}"
    return
  fi
  pass_case "${name}"
}
case_publish_failure_propagates

# ---------------------------------------------------------------------------
# Wiring: each credential env var publish.sh accepts is set in the Publish
# step from the matching action input, and cd-release feeds that input from
# the matching repository secret. Triples: env var, action input, secret.
# ---------------------------------------------------------------------------
case_wiring() {
  local env_var="$1" input="$2" secret="$3"
  local name="wiring-${env_var}"
  if ! grep -qF "${env_var}) secret=${secret} ;;" "${publish_sh}"; then
    fail_case "${name}" "publish.sh does not map ${env_var} to the ${secret} secret"
    return
  fi
  if ! grep -qF "${env_var}: \${{ inputs.${input} }}" "${action_yml}"; then
    fail_case "${name}" "action.yml does not set ${env_var} from inputs.${input}"
    return
  fi
  if ! grep -qF "${input}: \${{ secrets.${secret} }}" "${cd_release_yml}"; then
    fail_case "${name}" "cd-release.yml does not pass secrets.${secret} to ${input}"
    return
  fi
  if ! grep -qE "^      ${secret}:$" "${cd_release_yml}"; then
    fail_case "${name}" "cd-release.yml does not declare the ${secret} secret"
    return
  fi
  pass_case "${name}"
}
case_wiring CARGO_REGISTRY_TOKEN cargo-registry-token CARGO_REGISTRY_TOKEN
case_wiring MAVEN_GPG_PASSPHRASE gpg-passphrase GPG_PASSPHRASE

# Ruby support was removed (vergil-tooling#3388): no RubyGems wiring remains.
case_no_ruby() {
  local name="no-ruby-leftovers"
  local hits
  hits="$(grep -n -i -E "ruby|rubygems|GEM_HOST" \
    "${action_yml}" "${publish_sh}" "${cd_release_yml}" || true)"
  if [ -n "${hits}" ]; then
    fail_case "${name}" "Ruby leftovers remain: ${hits}"
    return
  fi
  pass_case "${name}"
}
case_no_ruby

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
