#!/usr/bin/env bash
#
# Test that push-tag.sh pushes with the App token it is given and only that
# token, even when the checkout left its own Authorization header in the
# repository's git config (vergil-project/vergil-actions#1315).
#
# Framework-free and developer-runnable: `bash push-tag.test.sh`. It needs
# git and python3. No case leaves the machine: each push goes to a local HTTP
# server that records the Authorization headers of every request and answers
# 403, so the push itself fails and the test reads what git sent.
#
# Cases:
#   * the checkout's header in the local config (actions/checkout up to v5)
#     is replaced: the server sees exactly one Authorization header, the App
#     token's;
#   * the checkout's header in an included file (actions/checkout v6) is
#     replaced the same way;
#   * a GIT_CONFIG_COUNT already in the environment is kept, not overwritten;
#   * an empty TAG_TOKEN fails with an error naming the tag-token input, and
#     nothing reaches the server;
#   * no push arguments fails before git runs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../push-tag.sh"

for tool in git python3 base64; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'push-tag.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done

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
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# The server appends one line per request: the request path, its User-Agent,
# then every Authorization header value, tab-separated.
log="${work}/requests.log"
portfile="${work}/port"
: >"$log"
cat >"${work}/server.py" <<'PY'
import http.server
import sys

log_path, port_path = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def _record(self):
        auth = self.headers.get_all("Authorization") or []
        with open(log_path, "a", encoding="utf-8") as fh:
            ua = self.headers.get("User-Agent", "")
            fh.write("\t".join([self.path, ua] + auth) + "\n")
        self.send_response(403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = _record
    do_POST = _record

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="utf-8") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 -I "${work}/server.py" "$log" "$portfile" &
server_pid=$!
for _ in $(seq 1 50); do
  [ -s "$portfile" ] && break
  sleep 0.1
done
if [ ! -s "$portfile" ]; then
  printf 'push-tag.test.sh: the local HTTP server did not start\n' >&2
  exit 1
fi
server_url="http://127.0.0.1:$(cat "$portfile")"

b64() { printf 'x-access-token:%s' "$1" | base64 | tr -d '\n'; }
checkout_header="AUTHORIZATION: basic $(b64 checkout-token)"
# What the server receives as the header's value.
app_header="basic $(b64 app-token)"

# new_repo <name> — a repo with one tagged commit and an `origin` on the
# local server. Prints its path.
new_repo() {
  local repo="${work}/$1"
  git init --quiet "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid \
    commit --quiet --allow-empty -m init
  git -C "$repo" tag v1.2.3
  git -C "$repo" remote add origin "${server_url}/owner/repo.git"
  printf '%s\n' "$repo"
}

# run_push <repo> <token> [args...] — run push-tag.sh in <repo> with a clean
# git environment. Sets rc and out.
run_push() {
  local repo="$1" token="$2"
  shift 2
  : >"$log"
  set +e
  out="$(cd "$repo" && env -u GIT_CONFIG_COUNT HOME="$work" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 GITHUB_SERVER_URL="$server_url" TAG_TOKEN="$token" \
    bash "$script" "$@" 2>&1)"
  rc=$?
  set -e
}

# expect_only_app_header <case> — every request carried exactly the App
# token's Authorization header, and there was at least one request.
expect_only_app_header() {
  local name="$1" line path rest
  if [ ! -s "$log" ]; then
    fail_case "$name" "no request reached the server (push output: ${out})"
    return 1
  fi
  while IFS= read -r line; do
    path="$(printf '%s\n' "$line" | cut -f 1)"
    rest="$(printf '%s\n' "$line" | cut -f 3-)"
    if [ -z "$rest" ]; then
      fail_case "$name" "request ${path} carried no Authorization header"
      return 1
    fi
    if [ "$rest" != "$app_header" ]; then
      fail_case "$name" "request ${path} carried '${rest}', want only the App token's header"
      return 1
    fi
  done <"$log"
}

case_local_config_header_replaced() {
  local name="checkout-header-in-local-config-replaced" repo
  repo="$(new_repo local)"
  git -C "$repo" config "http.${server_url}/.extraheader" "$checkout_header"
  run_push "$repo" app-token origin v1.2.3
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "the push succeeded against a server that answers 403"
    return 0
  fi
  expect_only_app_header "$name" || return 0
  pass_case "$name"
}

case_included_config_header_replaced() {
  local name="checkout-header-in-included-file-replaced" repo inc
  repo="$(new_repo included)"
  inc="${work}/git-credentials.config"
  git config --file "$inc" "http.${server_url}/.extraheader" "$checkout_header"
  git -C "$repo" config "includeIf.gitdir:${repo}/.git.path" "$inc"
  # Prove the include is live, or the case would pass vacuously.
  if [ "$(git -C "$repo" config --get "http.${server_url}/.extraheader")" != "$checkout_header" ]; then
    fail_case "$name" "the fixture's included checkout header is not visible to git"
    return 0
  fi
  run_push "$repo" app-token origin v1.2.3
  expect_only_app_header "$name" || return 0
  pass_case "$name"
}

case_existing_config_count_kept() {
  local name="existing-git-config-count-kept" repo ua
  repo="$(new_repo count)"
  : >"$log"
  set +e
  out="$(cd "$repo" && HOME="$work" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    GITHUB_SERVER_URL="$server_url" TAG_TOKEN=app-token \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.userAgent GIT_CONFIG_VALUE_0=push-tag-test \
    bash "$script" origin v1.2.3 2>&1)"
  set -e
  expect_only_app_header "$name" || return 0
  # The caller's command-line config still reached git.
  ua="$(head -n 1 "$log" | cut -f 2)"
  if [ "$ua" != "push-tag-test" ]; then
    fail_case "$name" "the caller's GIT_CONFIG_KEY_0 was lost: User-Agent '${ua}'"
    return 0
  fi
  pass_case "$name"
}

case_empty_token_refused() {
  local name="empty-token-refused" repo
  repo="$(new_repo empty)"
  git -C "$repo" config "http.${server_url}/.extraheader" "$checkout_header"
  run_push "$repo" "" origin v1.2.3
  if [ "$rc" -eq 0 ]; then
    fail_case "$name" "push-tag.sh exited 0 with an empty token"
    return 0
  fi
  case "$out" in
    *"::error::"*"tag-token input is empty"*) ;;
    *)
      fail_case "$name" "the error does not name the tag-token input: ${out}"
      return 0
      ;;
  esac
  if [ -s "$log" ]; then
    fail_case "$name" "a request reached the server: $(cat "$log")"
    return 0
  fi
  pass_case "$name"
}

case_no_arguments_refused() {
  local name="no-push-arguments-refused" repo
  repo="$(new_repo noargs)"
  run_push "$repo" app-token
  if [ "$rc" -eq 0 ] || [ -s "$log" ]; then
    fail_case "$name" "push-tag.sh ran git with no push arguments (rc=${rc})"
    return 0
  fi
  pass_case "$name"
}

case_local_config_header_replaced
case_included_config_header_replaced
case_existing_config_count_kept
case_empty_token_refused
case_no_arguments_refused

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
