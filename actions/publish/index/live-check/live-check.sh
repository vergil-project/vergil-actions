#!/usr/bin/env bash
#
# Post-deploy live check for the publish-index workflow (issue
# vergil-project/vergil-actions#1123).
#
# GitHub Pages can report a deployment `success` and active while its origin
# goes on serving the previous deployment (vergil-project/packages#46: the new
# InRelease never appeared and the new .deb returned 404). This script proves
# the site Pages now serves is the one this run built, or fails loudly.
#
# What identifies "the index this run built": the sha256 of every signed apt
# `InRelease` and every dnf `repomd.xml` under the built site. Each InRelease
# carries the signing time in its `Date:` line and its own signature, so two
# builds never share one; repomd.xml is checked as well so the dnf side of the
# same deployment is covered.
#
# Usage:
#   live-check.sh manifest <site-dir>
#       Print the manifest: one "<sha256> <path>" line per InRelease and
#       repomd.xml under <site-dir>, path relative to it, sorted by path.
#       Fails when the site holds no InRelease (nothing would identify it).
#
#   live-check.sh verify --base-url <url> --manifest <file> \
#       [--deployment <label>] [--attempts <n>] [--interval <seconds>]
#       Fetch <url>/<path> for every manifest line, with a fresh cache-busting
#       query string and no-cache request headers, until every file is served
#       with its manifest digest. Up to <n> rounds (default 30), <seconds>
#       apart (default 10): about five minutes. Exits 0 once every file
#       matches; otherwise prints one ::error:: per file still not live,
#       naming <label>, the URL, the expected digest and what was served
#       (HTTP status, digest, Last-Modified, X-Cache), and exits 1.
#
# There is no fallback: a malformed manifest, an empty base URL, a fetch
# error or a wrong file all fail the check. A fetch error or a non-200 status
# within the window is retried, because a deployment going live is exactly
# what is being waited for.
#
# Test seam: the script calls `curl` and `sleep` from PATH, so a harness can
# put fakes first (tests/live-check.test.sh).
set -euo pipefail

die() {
  printf '::error::%s\n' "$1"
  exit 1
}

# Resolved once, in the main shell, so a missing tool fails with its message
# rather than inside a command substitution.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  sha256_cmd=(shasum -a 256)
else
  die "live-check: neither sha256sum nor shasum is on PATH"
fi

sha256_of() {
  local out
  out="$("${sha256_cmd[@]}" "$1")"
  printf '%s' "${out%% *}"
}

cmd_manifest() {
  [ "$#" -eq 1 ] || die "live-check manifest: expected one argument, <site-dir>"
  local site="$1"
  [ -d "$site" ] || die "live-check manifest: site directory not found: ${site}"

  local files rel path digest n_inrelease=0
  files="$(cd "$site" && find . -type f \( -name InRelease -o -name repomd.xml \) |
    sed 's|^\./||' | LC_ALL=C sort)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      *' '*) die "live-check manifest: path contains a space: ${rel}" ;;
    esac
    case "$rel" in
      */InRelease | InRelease) n_inrelease=$((n_inrelease + 1)) ;;
    esac
  done <<<"$files"
  [ "$n_inrelease" -gt 0 ] ||
    die "live-check manifest: no InRelease under ${site}; nothing identifies the built index"

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    path="${site%/}/${rel}"
    digest="$(sha256_of "$path")"
    printf '%s %s\n' "$digest" "$rel"
  done <<<"$files"
}

# header_value <file> <name> — the last value of header <name> (any case) in a
# curl --dump-header file, or "-" when absent. Last, because --location dumps
# one header block per hop.
header_value() {
  local v
  v="$(tr -d '\r' <"$1" | awk -v want="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
    { i = index($0, ":"); if (i == 0) next
      name = tolower(substr($0, 1, i - 1))
      if (name == want) { val = substr($0, i + 1); sub(/^[ \t]+/, "", val); last = val } }
    END { print last }')"
  printf '%s' "${v:--}"
}

cmd_verify() {
  local base_url="" manifest="" deployment="this run's deployment"
  local attempts=30 interval=10
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base-url) base_url="${2-}"; shift 2 || die "live-check verify: --base-url needs a value" ;;
      --manifest) manifest="${2-}"; shift 2 || die "live-check verify: --manifest needs a value" ;;
      --deployment) deployment="${2-}"; shift 2 || die "live-check verify: --deployment needs a value" ;;
      --attempts) attempts="${2-}"; shift 2 || die "live-check verify: --attempts needs a value" ;;
      --interval) interval="${2-}"; shift 2 || die "live-check verify: --interval needs a value" ;;
      *) die "live-check verify: unknown argument: $1" ;;
    esac
  done

  [ -n "$base_url" ] || die "live-check verify: the Pages base URL is empty (the deploy step's page_url output)"
  case "$base_url" in
    https://* | http://*) ;;
    *) die "live-check verify: the Pages base URL is not an http(s) URL: ${base_url}" ;;
  esac
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || die "live-check verify: --attempts must be a positive integer, got '${attempts}'"
  [[ "$interval" =~ ^[0-9]+$ ]] || die "live-check verify: --interval must be a non-negative integer, got '${interval}'"
  [ -n "$manifest" ] || die "live-check verify: --manifest is required"
  [ -f "$manifest" ] || die "live-check verify: manifest file not found: ${manifest}"

  local -a digests=() paths=()
  local line digest rel
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [[ "$line" =~ ^([0-9a-f]{64})\ ([^[:space:]]+)$ ]] ||
      die "live-check verify: malformed manifest line: '${line}'"
    digest="${BASH_REMATCH[1]}"
    rel="${BASH_REMATCH[2]}"
    case "/${rel}/" in
      *'/../'* | *'/./'* | '//'*) die "live-check verify: unsafe manifest path: ${rel}" ;;
    esac
    digests+=("$digest")
    paths+=("$rel")
  done <"$manifest"
  [ "${#paths[@]}" -gt 0 ] || die "live-check verify: the manifest is empty; nothing identifies the built index"

  base_url="${base_url%/}"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: tmp is local.
  trap "rm -rf '${tmp}'" EXIT

  local n="${#paths[@]}" i round=1 pending url code rc got
  local -a live=() report=()
  for ((i = 0; i < n; i++)); do live[i]=0; report[i]="not fetched"; done

  while :; do
    pending=0
    for ((i = 0; i < n; i++)); do
      [ "${live[i]}" -eq 1 ] && continue
      url="${base_url}/${paths[i]}"
      rm -f "${tmp}/body" "${tmp}/headers"
      set +e
      code="$(curl --silent --show-error --location --max-time 30 \
        --header 'Cache-Control: no-cache' --header 'Pragma: no-cache' \
        --dump-header "${tmp}/headers" --output "${tmp}/body" \
        --write-out '%{http_code}' \
        "${url}?vrg-live-check=$(date +%s)-${round}-${RANDOM}" 2>"${tmp}/stderr")"
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        report[i]="fetch failed (curl exit ${rc}: $(tr '\n' ' ' <"${tmp}/stderr"))"
        pending=$((pending + 1))
        continue
      fi
      touch "${tmp}/headers"
      local meta
      meta="Last-Modified: $(header_value "${tmp}/headers" last-modified), X-Cache: $(header_value "${tmp}/headers" x-cache)"
      if [ "$code" != "200" ]; then
        report[i]="HTTP ${code} (${meta})"
        pending=$((pending + 1))
        continue
      fi
      got="$(sha256_of "${tmp}/body")"
      if [ "$got" = "${digests[i]}" ]; then
        live[i]=1
        echo "live: ${paths[i]} (round ${round}, ${meta})"
      else
        report[i]="HTTP 200 with sha256 ${got} (${meta})"
        pending=$((pending + 1))
      fi
    done

    if [ "$pending" -eq 0 ]; then
      echo "Pages is serving the index this run built: all ${n} file(s) match (${deployment}, ${base_url})."
      return 0
    fi
    if [ "$round" -ge "$attempts" ]; then
      break
    fi
    echo "round ${round}/${attempts}: ${pending} of ${n} file(s) not live yet; retrying in ${interval}s"
    sleep "$interval"
    round=$((round + 1))
  done

  for ((i = 0; i < n; i++)); do
    [ "${live[i]}" -eq 1 ] && continue
    printf '::error::GitHub Pages reported %s successful, but after %d round(s) %s/%s is not the file this run built: expected sha256 %s, got %s\n' \
      "$deployment" "$attempts" "$base_url" "${paths[i]}" "${digests[i]}" "${report[i]}"
  done
  printf '::error::Pages is not serving the index this run built (%d of %d file(s) wrong after %d round(s), %ss apart): %s is likely still serving an older deployment. Re-run this workflow; if it repeats, raise it with GitHub Support.\n' \
    "$pending" "$n" "$attempts" "$interval" "$base_url"
  return 1
}

[ "$#" -ge 1 ] || die "live-check: expected a subcommand, manifest or verify"
sub="$1"
shift
case "$sub" in
  manifest) cmd_manifest "$@" ;;
  verify) cmd_verify "$@" ;;
  *) die "live-check: unknown subcommand: ${sub}" ;;
esac
