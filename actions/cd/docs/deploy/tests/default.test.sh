#!/usr/bin/env bash
#
# Test that actions/cd/docs/deploy/deploy.sh keeps a released site's default
# version through a develop deploy, and still makes `dev` the default of a site
# with no release yet (issue #1214).
#
# Framework-free and developer-runnable: `bash default.test.sh`. CI runs it from
# .github/workflows/smoke-cd-docs.yml in the prod-base image cd-docs.yml
# deploys from. It needs the real `mike` and `mkdocs`, `git` and `python3` on
# PATH. Each case deploys to a throwaway bare `origin` in a temporary
# directory, so no case touches the network, and git reads a temporary global
# config only.
#
# The default version is the root index.html that `mike set-default` writes,
# so each case reads the redirect target from origin's gh-pages branch.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_sh="$(cd "${here}/.." && pwd)/deploy.sh"

for tool in mike mkdocs git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'default.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${scratch}/gitconfig"
git config --global user.name "default.test.sh"
git config --global user.email "default-test@example.invalid"
git config --global init.defaultBranch develop
git config --global advice.detachedHead false

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

# new_site <name> — a work clone of a fresh bare origin holding a minimal MkDocs
# project, with no gh-pages branch yet. Prints the work clone's path.
new_site() {
  local dir="${scratch}/$1"
  git init -q --bare "${dir}/origin.git"
  git init -q "${dir}/work"
  mkdir -p "${dir}/work/docs"
  printf 'site_name: default-test\n' >"${dir}/work/mkdocs.yml"
  printf '# default-test\n' >"${dir}/work/docs/index.md"
  git -C "${dir}/work" add mkdocs.yml docs/index.md
  git -C "${dir}/work" commit -q -m "docs"
  git -C "${dir}/work" remote add origin "${dir}/origin.git"
  git -C "${dir}/work" push -q origin develop
  printf '%s\n' "${dir}/work"
}

# deploy <work> <version> <alias> [mike-command] — run deploy.sh in <work> as
# the action's "Deploy docs" step would. An empty <alias> is a develop deploy.
deploy() {
  (
    cd "$1"
    SCHEME=semver MIKE_CMD="${4:-mike}" MKDOCS_CMD=mkdocs \
      MKDOCS_CONFIG=mkdocs.yml DOC_VERSION="$2" DOC_ALIAS="$3" \
      bash "$deploy_sh"
  ) >"${scratch}/deploy.log" 2>&1
}

# default_of <work> — the version origin's site root redirects to.
default_of() {
  git -C "$1" fetch -q origin gh-pages
  git -C "$1" show FETCH_HEAD:index.html |
    sed -n 's/.*http-equiv="refresh" content="[0-9]*; url=\([^"]*\)\/".*/\1/p'
}

# check_default <case> <work> <want>
check_default() {
  local got
  got="$(default_of "$2")"
  if [[ "$got" == "$3" ]]; then
    pass_case "$1"
  else
    fail_case "$1" "site root redirects to '${got}', want '$3'"
  fi
}

# A site with no release: a develop deploy makes dev the default.
work="$(new_site unreleased)"
if deploy "$work" dev ""; then
  check_default "a develop deploy to a site with no release makes dev the default" "$work" dev
else
  fail_case "a develop deploy to a site with no release" "deploy.sh failed: $(cat "${scratch}/deploy.log")"
fi

# A second develop deploy before any release changes nothing and succeeds
# (mike set-default only warns when the redirect is already dev).
if deploy "$work" dev ""; then
  check_default "a repeated develop deploy before a release keeps dev the default" "$work" dev
else
  fail_case "a repeated develop deploy before a release" "deploy.sh failed: $(cat "${scratch}/deploy.log")"
fi

# A release makes latest the default.
if deploy "$work" 0.1 latest; then
  check_default "a release deploy makes latest the default" "$work" latest
else
  fail_case "a release deploy" "deploy.sh failed: $(cat "${scratch}/deploy.log")"
fi

# The root cause: mike's own `list` output never names the default version, so
# no guard can read it there. The text output is the same whatever the default.
listing="$(cd "$work" && mike list -F mkdocs.yml)"
if [[ "$listing" == *default* ]]; then
  fail_case "mike list never names the default version" "it printed: ${listing}"
else
  pass_case "mike list never names the default version"
fi

# The bug: a develop deploy after a release keeps latest the default and still
# deploys dev.
if deploy "$work" dev ""; then
  check_default "a develop deploy after a release keeps latest the default" "$work" latest
  versions="$(cd "$work" && mike list -F mkdocs.yml --json)"
  if printf '%s' "$versions" | python3 -c '
import json, sys
sys.exit(0 if "dev" in [v["version"] for v in json.load(sys.stdin)] else 1)
'; then
    pass_case "a develop deploy after a release still deploys dev"
  else
    fail_case "a develop deploy after a release still deploys dev" "versions: ${versions}"
  fi
else
  fail_case "a develop deploy after a release" "deploy.sh failed: $(cat "${scratch}/deploy.log")"
fi

# A `mike list` that fails stops the deploy and leaves the default alone,
# rather than reading as "no release" and resetting it to dev.
failing_mike="${scratch}/failing-mike"
# The lines are the fake mike's own source; its $1 and $@ must not expand here.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = list ]; then echo "mike list: simulated failure" >&2; exit 1; fi' \
  'exec mike "$@"' >"$failing_mike"
chmod +x "$failing_mike"
if deploy "$work" dev "" "$failing_mike"; then
  fail_case "a failing mike list stops a develop deploy" "deploy.sh exited 0: $(cat "${scratch}/deploy.log")"
elif ! grep -q 'mike list failed' "${scratch}/deploy.log"; then
  fail_case "a failing mike list stops a develop deploy" "no 'mike list failed' error: $(cat "${scratch}/deploy.log")"
else
  check_default "a failing mike list stops a develop deploy and keeps latest the default" "$work" latest
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
