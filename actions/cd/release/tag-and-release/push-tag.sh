#!/usr/bin/env bash
#
# Push release tags with the automation App's installation token, never the
# checkout's GITHUB_TOKEN (vergil-project/vergil-actions#1315, epic
# vergil-project/.github#1350). Every tag push of tag-and-release goes
# through here: the `v<version>` tag and the resync of a tag with missing
# objects.
#
# Only the repository Admin role and the automation App may create, update or
# delete a release tag once the Tag protection ruleset carries its creation
# rule, so a push as the checkout's `github-actions[bot]` would be refused.
#
# actions/checkout leaves its token as an `http.<server>/.extraheader`
# Authorization header in the repository's git config. git sends every value
# of that key, so this script first resets the list (an empty value) and then
# sets the App token's header, both as command-line config passed through
# GIT_CONFIG_COUNT (read after every config file, and kept out of argv).
#
# The logic lives here (not inline in action.yml) so it is testable
# (tests/push-tag.test.sh runs it against a local HTTP server).
#
# Inputs (env): TAG_TOKEN (the App installation token; required),
# GITHUB_SERVER_URL (set by the runner, e.g. https://github.com).
# Arguments: passed to `git push` unchanged (e.g. `origin v1.2.3`).
set -euo pipefail

if [ -z "${TAG_TOKEN:-}" ]; then
  echo "::error::tag-and-release: the tag-token input is empty. Release tags are pushed only with the automation App's installation token (actions/create-github-app-token with APP_CLIENT_ID and APP_PRIVATE_KEY), never the checkout's GITHUB_TOKEN. Nothing was pushed."
  exit 1
fi
if [ -z "${GITHUB_SERVER_URL:-}" ]; then
  echo "::error::tag-and-release: GITHUB_SERVER_URL is not set, so the push credential has no server to apply to. Nothing was pushed."
  exit 1
fi
if [ "$#" -eq 0 ]; then
  echo "::error::tag-and-release: push-tag.sh needs the git push arguments (remote and tag). Nothing was pushed."
  exit 1
fi

basic="$(printf 'x-access-token:%s' "$TAG_TOKEN" | base64 | tr -d '\n')"
# The runner masks the token itself, not its base64 form.
echo "::add-mask::${basic}"

key="http.${GITHUB_SERVER_URL%/}/.extraheader"
n="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${n}=${key}" "GIT_CONFIG_VALUE_${n}="
n=$((n + 1))
export "GIT_CONFIG_KEY_${n}=${key}" "GIT_CONFIG_VALUE_${n}=AUTHORIZATION: basic ${basic}"
export GIT_CONFIG_COUNT=$((n + 1))

git push "$@"
