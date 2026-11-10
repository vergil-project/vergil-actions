#!/usr/bin/env bash
#
# Behavioural test for live-check.sh — the publish-index post-deploy live
# check (issue #1123) — plus a static check of its wiring in publish-index.yml.
#
# Framework-free and developer-runnable: `bash live-check.test.sh`. CI runs it
# from .github/workflows/smoke-publish-index.yml.
#
# verify cases run the script with a fake `curl` and a fake `sleep` first on
# PATH. The fake curl serves files from a fixture tree chosen by the round
# number in the cache-busting query (<root>/<round>/, else <root>/default/),
# writes Last-Modified and X-Cache headers, answers 404 for a missing file,
# and logs every request so the cache-busting and no-cache headers can be
# asserted. The fake sleep only logs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_dir="${here}/.."
script="${action_dir}/live-check.sh"
repo_root="$(cd "${action_dir}/../../../.." && pwd)"
workflow="${repo_root}/.github/workflows/publish-index.yml"
base="https://example.test/packages/"

pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail_case() {
  printf 'not ok - %s: %s\n' "$1" "$2" >&2
  fail=$((fail + 1))
}

pass_case() {
  printf 'ok - %s\n' "$1"
  pass=$((pass + 1))
}

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Fakes (tests/fixtures/curl and tests/fixtures/sleep), first on PATH.
bin="${work}/bin"
mkdir -p "${bin}"
cp "${here}/fixtures/curl" "${here}/fixtures/sleep" "${bin}/"
chmod +x "${bin}/curl" "${bin}/sleep"

# make_site <dir> <tag> — a built site whose InRelease/repomd.xml content
# carries <tag>, plus files the manifest must ignore.
make_site() {
  local d="$1" tag="$2"
  mkdir -p "${d}/deb/dists/noble" "${d}/deb/dists/jammy" \
    "${d}/rpm/el9/x86_64/repodata" "${d}/deb/pool/main" "${d}/keys"
  printf 'Date: %s\nSuite: noble\n' "$tag" >"${d}/deb/dists/noble/InRelease"
  printf 'Date: %s\nSuite: jammy\n' "$tag" >"${d}/deb/dists/jammy/InRelease"
  printf '<repomd>%s</repomd>\n' "$tag" >"${d}/rpm/el9/x86_64/repodata/repomd.xml"
  printf 'Date: %s\n' "$tag" >"${d}/deb/dists/noble/Release"
  printf 'deb\n' >"${d}/deb/pool/main/tool_1.0_amd64.deb"
  printf 'key\n' >"${d}/keys/vergil.asc"
  printf '%s\n' "$tag" >"${d}/.last-modified"
}

# run_cmd <args...> — run live-check.sh; sets out and rc.
run_cmd() {
  set +e
  out="$(bash "${script}" "$@" 2>&1)"
  rc=$?
  set -e
}

# run_verify <case-dir> <args...> — verify against the fake server rooted at
# <case-dir>/served; sets out, rc and the logs.
run_verify() {
  local d="$1"
  shift
  : >"${d}/curl.log"
  : >"${d}/sleep.log"
  set +e
  out="$(PATH="${bin}:${PATH}" FAKE_ROOT="${d}/served" FAKE_BASE="${base}" \
    FAKE_CURL_LOG="${d}/curl.log" FAKE_SLEEP_LOG="${d}/sleep.log" \
    bash "${script}" verify --base-url "${base}" "$@" 2>&1)"
  rc=$?
  set -e
}

expect_rc() {
  local name="$1" want="$2"
  if [ "$want" = 0 ] && [ "$rc" -ne 0 ]; then
    fail_case "$name" "expected exit 0, got ${rc}; output: ${out}"
    return 1
  fi
  if [ "$want" != 0 ] && [ "$rc" -eq 0 ]; then
    fail_case "$name" "expected non-zero exit, got 0; output: ${out}"
    return 1
  fi
  return 0
}

expect_out() {
  local name="$1" pattern="$2"
  if ! printf '%s\n' "$out" | grep -qE -- "$pattern"; then
    fail_case "$name" "expected output matching '${pattern}'; output: ${out}"
    return 1
  fi
  return 0
}

new_case() {
  local d="${work}/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------
case_manifest_lists_index_files() {
  local name="manifest-lists-inrelease-and-repomd-sorted"
  local d
  d="$(new_case "$name")"
  make_site "${d}/site" "new"
  run_cmd manifest "${d}/site"
  expect_rc "$name" 0 || return
  local want
  want="$(printf '%s deb/dists/jammy/InRelease\n%s deb/dists/noble/InRelease\n%s rpm/el9/x86_64/repodata/repomd.xml' \
    "$(sha "${d}/site/deb/dists/jammy/InRelease")" \
    "$(sha "${d}/site/deb/dists/noble/InRelease")" \
    "$(sha "${d}/site/rpm/el9/x86_64/repodata/repomd.xml")")"
  if [ "$out" != "$want" ]; then
    fail_case "$name" "manifest mismatch; want: ${want}; got: ${out}"
    return
  fi
  pass_case "$name"
}
case_manifest_lists_index_files

case_manifest_without_inrelease_fails() {
  local name="manifest-without-inrelease-fails"
  local d
  d="$(new_case "$name")"
  mkdir -p "${d}/site/rpm/el9/x86_64/repodata"
  printf 'x\n' >"${d}/site/rpm/el9/x86_64/repodata/repomd.xml"
  run_cmd manifest "${d}/site"
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*no InRelease' || return
  pass_case "$name"
}
case_manifest_without_inrelease_fails

case_manifest_missing_site_fails() {
  local name="manifest-missing-site-fails"
  run_cmd manifest "${work}/does-not-exist"
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*site directory not found' || return
  pass_case "$name"
}
case_manifest_missing_site_fails

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# setup_verify <case-dir> — build the new site, its manifest, and an old site.
setup_verify() {
  local d="$1"
  make_site "${d}/new" "Tue, 10 Nov 2026 12:00:00 GMT"
  make_site "${d}/old" "Mon, 09 Nov 2026 12:00:00 GMT"
  bash "${script}" manifest "${d}/new" >"${d}/manifest"
  mkdir -p "${d}/served"
}

case_verify_live_first_round() {
  local name="verify-passes-when-live-at-once"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  cp -R "${d}/new" "${d}/served/default"
  run_verify "$d" --manifest "${d}/manifest" --attempts 3 --interval 5
  expect_rc "$name" 0 || return
  expect_out "$name" 'all 3 file\(s\) match' || return
  if [ -s "${d}/sleep.log" ]; then
    fail_case "$name" "slept although live at once: $(cat "${d}/sleep.log")"
    return
  fi
  if [ "$(wc -l <"${d}/curl.log" | tr -d ' ')" != 3 ]; then
    fail_case "$name" "expected 3 requests; log: $(cat "${d}/curl.log")"
    return
  fi
  pass_case "$name"
}
case_verify_live_first_round

case_verify_goes_live_later() {
  local name="verify-retries-until-live"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  cp -R "${d}/old" "${d}/served/1"
  cp -R "${d}/old" "${d}/served/2"
  cp -R "${d}/new" "${d}/served/default"
  run_verify "$d" --manifest "${d}/manifest" --attempts 5 --interval 7
  expect_rc "$name" 0 || return
  if [ "$(cat "${d}/sleep.log")" != "$(printf '7\n7')" ]; then
    fail_case "$name" "expected two 7s sleeps; got: $(cat "${d}/sleep.log")"
    return
  fi
  pass_case "$name"
}
case_verify_goes_live_later

case_verify_stale_fails() {
  local name="verify-fails-on-stale-deployment"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  cp -R "${d}/old" "${d}/served/default"
  run_verify "$d" --manifest "${d}/manifest" --attempts 3 --interval 1 \
    --deployment "the Pages deployment of o/p run 42 attempt 1"
  expect_rc "$name" 1 || return
  local want_sha got_sha
  want_sha="$(sha "${d}/new/deb/dists/noble/InRelease")"
  got_sha="$(sha "${d}/old/deb/dists/noble/InRelease")"
  expect_out "$name" "^::error::GitHub Pages reported the Pages deployment of o/p run 42 attempt 1 successful, but after 3 round\(s\) https://example.test/packages/deb/dists/noble/InRelease is not the file this run built: expected sha256 ${want_sha}, got HTTP 200 with sha256 ${got_sha} \(Last-Modified: Mon, 09 Nov 2026 12:00:00 GMT, X-Cache: MISS\)" || return
  expect_out "$name" '^::error::Pages is not serving the index this run built \(3 of 3 file\(s\) wrong after 3 round\(s\), 1s apart\).*older deployment.*Re-run' || return
  if [ "$(wc -l <"${d}/sleep.log" | tr -d ' ')" != 2 ]; then
    fail_case "$name" "expected 2 sleeps for 3 rounds; got: $(cat "${d}/sleep.log")"
    return
  fi
  pass_case "$name"
}
case_verify_stale_fails

case_verify_404_fails() {
  local name="verify-fails-on-404"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  mkdir -p "${d}/served/default"
  run_verify "$d" --manifest "${d}/manifest" --attempts 2 --interval 0
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*InRelease is not the file this run built: expected sha256 [0-9a-f]{64}, got HTTP 404 \(Last-Modified: -, X-Cache: HIT\)' || return
  pass_case "$name"
}
case_verify_404_fails

case_verify_fetch_error_fails() {
  local name="verify-fails-on-fetch-error"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  mkdir -p "${d}/served/default"
  printf '6' >"${d}/served/default/.curl-exit"
  run_verify "$d" --manifest "${d}/manifest" --attempts 2 --interval 0
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*got fetch failed \(curl exit 6: curl: \(6\) Could not resolve host' || return
  pass_case "$name"
}
case_verify_fetch_error_fails

case_verify_partial_names_only_wrong() {
  local name="verify-partial-names-only-wrong-file"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  cp -R "${d}/new" "${d}/served/default"
  cp "${d}/old/rpm/el9/x86_64/repodata/repomd.xml" \
    "${d}/served/default/rpm/el9/x86_64/repodata/repomd.xml"
  run_verify "$d" --manifest "${d}/manifest" --attempts 2 --interval 0
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*repomd.xml is not the file' || return
  if printf '%s\n' "$out" | grep -qE '^::error::.*InRelease is not the file'; then
    fail_case "$name" "a live InRelease was reported wrong; output: ${out}"
    return
  fi
  # Round 1 fetches 3 files; round 2 only the one still wrong.
  if [ "$(wc -l <"${d}/curl.log" | tr -d ' ')" != 4 ]; then
    fail_case "$name" "expected 4 requests; log: $(cat "${d}/curl.log")"
    return
  fi
  expect_out "$name" '1 of 3 file\(s\) wrong' || return
  pass_case "$name"
}
case_verify_partial_names_only_wrong

case_verify_cache_busting() {
  local name="verify-busts-caches"
  local d
  d="$(new_case "$name")"
  setup_verify "$d"
  cp -R "${d}/old" "${d}/served/default"
  run_verify "$d" --manifest "${d}/manifest" --attempts 2 --interval 0
  local bad
  bad="$(grep -vE '^https://example\.test/packages/[^?]+\?vrg-live-check=[0-9]+-[12]-[0-9]+[|]Cache-Control: no-cache Pragma: no-cache$' "${d}/curl.log" || true)"
  if [ -n "$bad" ]; then
    fail_case "$name" "request without cache busting: ${bad}"
    return
  fi
  local n uniq
  n="$(wc -l <"${d}/curl.log" | tr -d ' ')"
  uniq="$(cut -d'|' -f1 "${d}/curl.log" | sort -u | wc -l | tr -d ' ')"
  if [ "$n" != 6 ] || [ "$uniq" != 6 ]; then
    fail_case "$name" "expected 6 distinct URLs, got ${uniq} of ${n}"
    return
  fi
  if grep -q 'packages//' "${d}/curl.log"; then
    fail_case "$name" "double slash joining base URL and path"
    return
  fi
  pass_case "$name"
}
case_verify_cache_busting

# expect_verify_refused <name> <pattern> <manifest content> <args...>
expect_verify_refused() {
  local name="$1" pattern="$2" content="$3"
  shift 3
  local d
  d="$(new_case "$name")"
  mkdir -p "${d}/served/default"
  printf '%s' "$content" >"${d}/manifest"
  run_verify "$d" --manifest "${d}/manifest" "$@"
  expect_rc "$name" 1 || return
  expect_out "$name" "^::error::.*${pattern}" || return
  if [ -s "${d}/curl.log" ]; then
    fail_case "$name" "fetched despite the refusal"
    return
  fi
  pass_case "$name"
}

good_line="$(printf 'a%.0s' $(seq 64)) deb/dists/noble/InRelease"
expect_verify_refused "verify-refuses-empty-manifest" "manifest is empty" ""
expect_verify_refused "verify-refuses-malformed-manifest" "malformed manifest line" \
  "abc deb/dists/noble/InRelease"
expect_verify_refused "verify-refuses-unsafe-path" "unsafe manifest path" \
  "$(printf 'a%.0s' $(seq 64)) ../etc/passwd"
expect_verify_refused "verify-refuses-bad-attempts" "attempts must be a positive integer" \
  "$good_line" --attempts 0
expect_verify_refused "verify-refuses-bad-interval" "interval must be a non-negative integer" \
  "$good_line" --interval x

case_verify_empty_base_url() {
  local name="verify-refuses-empty-base-url"
  run_cmd verify --base-url "" --manifest /dev/null
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*base URL is empty.*page_url' || return
  pass_case "$name"
}
case_verify_empty_base_url

case_verify_missing_manifest_file() {
  local name="verify-refuses-missing-manifest-file"
  run_cmd verify --base-url "$base" --manifest "${work}/nope"
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*manifest file not found' || return
  pass_case "$name"
}
case_verify_missing_manifest_file

case_unknown_subcommand() {
  local name="unknown-subcommand-fails"
  run_cmd frobnicate
  expect_rc "$name" 1 || return
  expect_out "$name" '^::error::.*unknown subcommand' || return
  pass_case "$name"
}
case_unknown_subcommand

# ---------------------------------------------------------------------------
# Wiring: build-index records the manifest and exports it; deploy verifies
# against the deploy step's page_url with that manifest, after the deploy.
# ---------------------------------------------------------------------------
case_wiring() {
  local name="wiring-publish-index"
  local want
  for want in \
    "index-manifest: \${{ steps.manifest.outputs.manifest }}" \
    'uses: ./actions/publish/index/live-check' \
    'mode: manifest' \
    'mode: verify' \
    "base-url: \${{ steps.deployment.outputs.page_url }}" \
    "manifest: \${{ needs.build-index.outputs.index-manifest }}"; do
    if ! grep -qF -- "$want" "$workflow"; then
      fail_case "$name" "publish-index.yml lacks: ${want}"
      return
    fi
  done
  local deploy_line verify_line upload_line manifest_line
  manifest_line="$(grep -nF 'mode: manifest' "$workflow" | cut -d: -f1)"
  upload_line="$(grep -nF 'uses: actions/upload-pages-artifact' "$workflow" | cut -d: -f1)"
  deploy_line="$(grep -nF 'uses: actions/deploy-pages' "$workflow" | cut -d: -f1)"
  verify_line="$(grep -nF 'mode: verify' "$workflow" | cut -d: -f1)"
  if [ "$manifest_line" -ge "$upload_line" ] || [ "$verify_line" -le "$deploy_line" ]; then
    fail_case "$name" "the manifest must precede the upload and the verify must follow the deploy"
    return
  fi
  pass_case "$name"
}
case_wiring

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
