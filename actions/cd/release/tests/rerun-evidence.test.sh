#!/usr/bin/env bash
#
# Test that a re-run of cd-release's release job on a release that is
# already tagged and published gates, attests and attaches a missing CI
# evidence bundle, or fails, and never reports success without one
# (vergil-project/vergil-actions#1439, epic vergil-project/.github#1384).
# Seen in vergil-project/vergil-fixture-ts-lib's CD run 45506188123:
# attempt 1 tagged and published v0.1.10, then failed at the evidence
# bundle's provenance attestation; attempt 2, a re-run, found the tag,
# skipped every evidence step on `steps.tag_check.outputs.exists ==
# 'false'`, and succeeded with no evidence bundle on the release.
#
# Framework-free and developer-runnable: `bash rerun-evidence.test.sh`. CI
# runs it from .github/workflows/smoke-cd-release.yml. It needs `yq`
# (mikefarah v4, preinstalled on GitHub's ubuntu runners). No case touches
# the network: `gh` is a stub on PATH.
#
# Cases:
#   * the "Check the release's CI evidence" step runs on every release,
#     after the tag check and before the App secrets check, the evidence
#     gate and anything published, with no condition and no
#     continue-on-error;
#   * every evidence step (the SBOM path, the gate, the attach and their
#     two enforcement guards) runs on that step's needed=true, not on the
#     tag check, and the guards keep their always() and enforcing form;
#   * every step that tags, publishes or dispatches still runs only when
#     the tag does not exist, so a re-run never re-tags or re-publishes;
#   * the check, run as written: a new tag needs evidence without reading
#     the release; a published release with both evidence assets needs
#     none; one missing either asset needs it, naming what is missing; one
#     whose release cannot be read fails, naming the tag; a tag on another
#     commit than the run's (a push with no version bump) needs none and
#     reads no release; a tag that does not resolve fails;
#   * the attach guard, run as written, fails naming the tag;
#   * the SBOM path step, run as written on a re-run, downloads the SBOM
#     from the release when it is an asset there, warns when it is not,
#     and fails when the release cannot be read; on a new release it
#     touches no release.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
cd_release_yml="${repo_root}/.github/workflows/cd-release.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'rerun-evidence.test.sh needs yq on PATH\n' >&2
  exit 1
fi
if [ ! -f "$cd_release_yml" ]; then
  printf 'rerun-evidence.test.sh: missing %s\n' "$cd_release_yml" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

# step_index <name> — the index of the named release-job step, or empty.
step_index() {
  yq -r ".jobs.release.steps | to_entries | .[] | select(.value.name == \"$1\") | .key" \
    "$cd_release_yml"
}

# q <step name> <yq path> — a field of the named release-job step.
q() {
  yq -r ".jobs.release.steps[] | select(.name == \"$1\") | $2" "$cd_release_yml"
}

# q_flat <step name> <yq path> — q with every run of whitespace, newlines
# included, made one space and none at either end (a folded `>-` keeps the
# line breaks of its more-indented lines).
q_flat() {
  local v
  v="$(q "$1" "$2")"
  v="$(tr -s '[:space:]' ' ' <<<"$v")"
  v="${v% }"
  printf '%s' "${v# }"
}

check_step="Check the release's CI evidence"
needed="steps.evidence_check.outputs.needed == 'true'"
new_tag="steps.tag_check.outputs.exists == 'false'"

# The gh stub: `gh release view <tag> --json assets --jq ...` prints
# $GH_ASSETS (one name per line) or, with GH_FAIL=1, fails;
# `gh release download <tag> --pattern <name> --dir <dir>` writes
# <dir>/<name>. Every call is logged to $GH_LOG.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${GH_FAIL:-0}" = "1" ]; then
  echo "HTTP 404: Not Found" >&2
  exit 1
fi
case "$1 $2" in
  "release view")
    if [ -n "${GH_ASSETS:-}" ]; then
      printf '%s\n' "$GH_ASSETS"
    fi
    ;;
  "release download")
    shift 3
    pattern="" dir="."
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pattern) pattern="$2"; shift 2 ;;
        --dir) dir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'sbom\n' >"$dir/$pattern"
    ;;
  *)
    echo "gh stub: unexpected call: $*" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# The checkout a step runs in: a repository with two commits, the
# release commit tagged v0.1.10 ($release_sha) and a later one
# ($later_sha) at HEAD.
repo="$tmp/repo"
mkdir -p "$repo"
git_q() {
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null
}
git_q init -q
git_q commit -q --allow-empty -m release
git_q tag -a v0.1.10 -m v0.1.10
git_q commit -q --allow-empty -m later
release_sha="$(git -C "$repo" rev-parse 'v0.1.10^{commit}')"
later_sha="$(git -C "$repo" rev-parse HEAD)"

# run_step <step name> <VAR=value>... — run the named step's script as
# GitHub runs a bash step, in a scratch copy of the checkout, with the gh
# stub on PATH. Sets rc, out (stdout and stderr), outputs (the
# GITHUB_OUTPUT file) and gh_calls (the stub's log).
run_step() {
  local step="$1" run ws
  shift
  run="$(q "$step" .run)"
  ws="$tmp/ws"
  rm -rf "$ws"
  cp -a "$repo" "$ws"
  : >"$tmp/github_output"
  : >"$tmp/gh_log"
  set +e
  out="$(cd "$ws" && env -i PATH="$tmp/bin:$PATH" HOME="$tmp" \
    GITHUB_OUTPUT="$tmp/github_output" GH_LOG="$tmp/gh_log" "$@" \
    bash --noprofile --norc -eo pipefail -c "$run" 2>&1)"
  rc=$?
  set -e
  outputs="$(cat "$tmp/github_output")"
  gh_calls="$(cat "$tmp/gh_log")"
}

tarball="v0.1.10-ci-evidence.tar.gz"
manifest="v0.1.10-ci-evidence-manifest.json"

case_check_wiring() {
  local name="evidence-check-runs-on-every-release-before-publish" s
  local -A at=()
  for s in "Check if tag already exists" "$check_step" \
    "Require the automation App secrets" "CI evidence gate (pre-publish)" \
    "Build and publish" "Tag and release"; do
    at["$s"]="$(step_index "$s")"
    if [ -z "${at[$s]}" ]; then
      fail_case "$name" "the release job has no step named '$s'"
      return 0
    fi
  done
  if ! [ "${at["Check if tag already exists"]}" -lt "${at[$check_step]}" ] ||
    ! [ "${at[$check_step]}" -lt "${at["Require the automation App secrets"]}" ] ||
    ! [ "${at[$check_step]}" -lt "${at["CI evidence gate (pre-publish)"]}" ]; then
    fail_case "$name" "the evidence check is not after the tag check and before the secrets check and the gate"
    return 0
  fi
  expect "$name" "id" "$(q "$check_step" .id)" "evidence_check" || return 0
  expect "$name" "if" "$(q "$check_step" '.if // "absent"')" "absent" || return 0
  expect "$name" "continue-on-error" \
    "$(q "$check_step" '."continue-on-error" // "absent"')" "absent" || return 0
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  {
    expect "$name" "TAG_EXISTS" "$(q "$check_step" .env.TAG_EXISTS)" \
      '${{ steps.tag_check.outputs.exists }}' || return 0
    expect "$name" "TAG" "$(q "$check_step" .env.TAG)" \
      '${{ steps.version.outputs.tag }}' || return 0
    expect "$name" "MERGE_SHA" "$(q "$check_step" .env.MERGE_SHA)" \
      '${{ github.sha }}' || return 0
    expect "$name" "GH_TOKEN" "$(q "$check_step" .env.GH_TOKEN)" \
      '${{ github.token }}' || return 0
    expect "$name" "GH_REPO" "$(q "$check_step" .env.GH_REPO)" \
      '${{ github.repository }}' || return 0
  }
  pass_case "$name"
}

case_evidence_steps_follow_the_check() {
  local name="evidence-steps-run-when-evidence-is-needed"
  expect "$name" "SBOM path if" "$(q "Resolve SBOM path for evidence" .if)" \
    "${needed} && inputs.sbom-output-file != ''" || return 0
  expect "$name" "gate if" "$(q "CI evidence gate (pre-publish)" .if)" "$needed" || return 0
  expect "$name" "attach if" "$(q "Attach CI evidence bundle (post-release)" .if)" \
    "$needed" || return 0
  # shellcheck disable=SC2016 # literal GitHub Actions expressions
  {
    expect "$name" "gate continue-on-error" \
      "$(q "CI evidence gate (pre-publish)" '."continue-on-error"')" \
      '${{ !inputs.evidence-enforce }}' || return 0
    expect "$name" "attach continue-on-error" \
      "$(q "Attach CI evidence bundle (post-release)" '."continue-on-error"')" \
      '${{ !inputs.evidence-enforce }}' || return 0
    expect "$name" "gate guard if" "$(q_flat "Enforce CI evidence gate" .if)" \
      "\${{ always() && inputs.evidence-enforce && ${needed} && (steps.evidence_gate.outcome == 'failure' || (steps.evidence_gate.outcome == 'success' && steps.evidence_gate.outputs.passed != 'true')) }}" ||
      return 0
    expect "$name" "attach guard if" "$(q_flat "Enforce CI evidence attach" .if)" \
      "\${{ always() && inputs.evidence-enforce && ${needed} && (steps.evidence_attach.outcome == 'failure' || (steps.evidence_attach.outcome == 'success' && steps.evidence_attach.outputs.attached != 'true')) }}" ||
      return 0
    expect "$name" "attach guard continue-on-error" \
      "$(q "Enforce CI evidence attach" '."continue-on-error" // "absent"')" "absent" || return 0
  }
  pass_case "$name"
}

case_publish_steps_only_on_a_new_tag() {
  local name="rerun-never-retags-or-republishes" s want got
  for s in "Require the automation App secrets" "Mint release tag token" \
    "Resolve release artifacts" "Tag and release"; do
    expect "$name" "'$s' if" "$(q "$s" .if)" "$new_tag" || return 0
  done
  for s in "Download signed packages" "Download package manifest" \
    "Stage package release assets" "Mint package-index dispatch token"; do
    expect "$name" "'$s' if" "$(q "$s" .if)" \
      "needs.package-matrix.outputs.enabled == 'true' && ${new_tag}" || return 0
  done
  want="contains(fromJSON('[\"python\",\"rust\",\"go\",\"typescript\"]'), inputs.language) && ${new_tag}"
  got="$(q "Build and publish" .if)"
  expect "$name" "'Build and publish' if" "$got" "$want" || return 0
  pass_case "$name"
}

case_check_new_tag() {
  local name="evidence-check-new-tag-needs-evidence"
  run_step "$check_step" TAG_EXISTS=false TAG=v0.1.10
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "needed=true" || return 0
  expect "$name" "gh calls" "$gh_calls" "" || return 0
  pass_case "$name"
}

case_check_evidence_present() {
  local name="evidence-check-published-release-with-evidence-is-unchanged"
  run_step "$check_step" TAG_EXISTS=true TAG=v0.1.10 MERGE_SHA="$release_sha" \
    GH_ASSETS="$(printf '%s\n' pkg.tgz "$manifest" "$tarball")"
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "needed=false" || return 0
  expect "$name" "gh calls" "$gh_calls" \
    "release view v0.1.10 --json assets --jq .assets[].name" || return 0
  case "$out" in
    *"::notice::"*"v0.1.10"*"already carries its CI evidence bundle"*) ;;
    *)
      fail_case "$name" "no notice that the release carries its evidence: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_check_evidence_missing() {
  local name="evidence-check-published-release-without-evidence-needs-it"
  # The real case: v0.1.10 of vergil-fixture-ts-lib had no assets at all.
  run_step "$check_step" TAG_EXISTS=true TAG=v0.1.10 MERGE_SHA="$release_sha" GH_ASSETS=""
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "needed=true" || return 0
  case "$out" in
    *"::warning::"*"v0.1.10"*"$tarball $manifest"*"not re-tagged or re-published"*) ;;
    *)
      fail_case "$name" "the warning does not name both missing assets: ${out}"
      return 0
      ;;
  esac
  # A half-attached bundle (the tarball uploaded, the manifest not) is
  # still missing its evidence.
  run_step "$check_step" TAG_EXISTS=true TAG=v0.1.10 MERGE_SHA="$release_sha" GH_ASSETS="$tarball"
  expect "$name" "half-attached exit" "$rc" "0" || return 0
  expect "$name" "half-attached outputs" "$outputs" "needed=true" || return 0
  case "$out" in
    *"::warning::"*"without $manifest:"*) ;;
    *)
      fail_case "$name" "the warning does not name only the manifest: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_check_unreadable_release() {
  local name="evidence-check-unreadable-release-fails"
  run_step "$check_step" TAG_EXISTS=true TAG=v0.1.10 MERGE_SHA="$release_sha" GH_FAIL=1
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the check passed when the release could not be read"
    return 0
  fi
  expect "$name" "outputs" "$outputs" "" || return 0
  case "$out" in
    *"::error::"*"v0.1.10"*"CI evidence"*) ;;
    *)
      fail_case "$name" "the error does not name the tag and its evidence: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_check_tag_on_another_commit() {
  local name="evidence-check-tag-on-another-commit-attaches-nothing"
  # A push to main with no version bump: the tag is an older release's,
  # which this commit's evidence does not belong to, even when that release
  # has no bundle.
  run_step "$check_step" TAG_EXISTS=true TAG=v0.1.10 MERGE_SHA="$later_sha" GH_ASSETS=""
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "needed=false" || return 0
  expect "$name" "gh calls" "$gh_calls" "" || return 0
  case "$out" in
    *"::notice::"*"v0.1.10"*"$release_sha"*"$later_sha"*"not a re-run"*) ;;
    *)
      fail_case "$name" "no notice naming the tag's and the run's commits: ${out}"
      return 0
      ;;
  esac
  # A tag that does not resolve to a commit fails the check.
  run_step "$check_step" TAG_EXISTS=true TAG=v9.9.9 MERGE_SHA="$release_sha" GH_ASSETS=""
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the check passed on a tag that does not resolve"
    return 0
  fi
  expect "$name" "unresolved outputs" "$outputs" "" || return 0
  case "$out" in
    *"::error::"*"v9.9.9"*) ;;
    *)
      fail_case "$name" "the error does not name the unresolved tag: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_attach_guard_fails() {
  local name="attach-guard-fails-naming-the-release"
  run_step "Enforce CI evidence attach" TAG=v0.1.10 ATTACH_OUTCOME=failure ATTACHED=""
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the attach guard passed"
    return 0
  fi
  case "$out" in
    *"::error::"*"v0.1.10"*"missing its evidence bundle"*) ;;
    *)
      fail_case "$name" "the error does not name the release's missing evidence: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

sbom_step="Resolve SBOM path for evidence"

case_sbom_new_release() {
  local name="sbom-path-new-release-reads-no-release"
  # shellcheck disable=SC2016 # the $VERSION placeholder is literal
  run_step "$sbom_step" TAG_EXISTS=false TAG=v0.1.10 VERSION=0.1.10 \
    SBOM_OUTPUT_FILE='dist/sbom-$VERSION.json'
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "path=dist/sbom-0.1.10.json" || return 0
  expect "$name" "gh calls" "$gh_calls" "" || return 0
  pass_case "$name"
}

case_sbom_rerun_downloads() {
  local name="sbom-path-rerun-downloads-the-released-sbom"
  # shellcheck disable=SC2016 # the $VERSION placeholder is literal
  run_step "$sbom_step" TAG_EXISTS=true TAG=v0.1.10 VERSION=0.1.10 \
    SBOM_OUTPUT_FILE='dist/sbom-$VERSION.json' \
    GH_ASSETS="$(printf '%s\n' sbom-0.1.10.json pkg.tgz)"
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "path=dist/sbom-0.1.10.json" || return 0
  if [ ! -f "$tmp/ws/dist/sbom-0.1.10.json" ]; then
    fail_case "$name" "the SBOM was not downloaded to its path: ${out}"
    return 0
  fi
  expect "$name" "gh calls" "$gh_calls" \
    "$(printf '%s\n' "release view v0.1.10 --json assets --jq .assets[].name" \
      "release download v0.1.10 --pattern sbom-0.1.10.json --dir dist")" || return 0
  pass_case "$name"
}

case_sbom_rerun_not_released() {
  local name="sbom-path-rerun-warns-when-the-sbom-is-not-released"
  # shellcheck disable=SC2016 # the $VERSION placeholder is literal
  run_step "$sbom_step" TAG_EXISTS=true TAG=v0.1.10 VERSION=0.1.10 \
    SBOM_OUTPUT_FILE='dist/sbom-$VERSION.json' GH_ASSETS="pkg.tgz"
  expect "$name" "exit" "$rc" "0" || return 0
  expect "$name" "outputs" "$outputs" "path=dist/sbom-0.1.10.json" || return 0
  case "$out" in
    *"::warning::"*"sbom-0.1.10.json"*"v0.1.10"*) ;;
    *)
      fail_case "$name" "no warning naming the SBOM and the release: ${out}"
      return 0
      ;;
  esac
  # shellcheck disable=SC2016 # the $VERSION placeholder is literal
  run_step "$sbom_step" TAG_EXISTS=true TAG=v0.1.10 VERSION=0.1.10 \
    SBOM_OUTPUT_FILE='dist/sbom-$VERSION.json' GH_FAIL=1
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the step passed when the release could not be read"
    return 0
  fi
  case "$out" in
    *"::error::"*"v0.1.10"*) ;;
    *)
      fail_case "$name" "the error does not name the release: ${out}"
      return 0
      ;;
  esac
  pass_case "$name"
}

case_check_wiring
case_evidence_steps_follow_the_check
case_publish_steps_only_on_a_new_tag
case_check_new_tag
case_check_evidence_present
case_check_evidence_missing
case_check_unreadable_release
case_check_tag_on_another_commit
case_attach_guard_fails
case_sbom_new_release
case_sbom_rerun_downloads
case_sbom_rerun_not_released

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
