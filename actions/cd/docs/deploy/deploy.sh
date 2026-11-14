#!/usr/bin/env bash
#
# Deploy the MkDocs site: the "Deploy docs" step of actions/cd/docs/deploy.
#
#   * versioning-scheme = none: one un-versioned site at the gh-pages root,
#     through `mkdocs gh-deploy --force` (issue #713).
#   * a release (DOC_ALIAS set, `latest` on main): `mike deploy` the version
#     with the alias, then make `latest` the site's default.
#   * a development deploy (no DOC_ALIAS, `dev` on develop): `mike deploy` the
#     version, and make `dev` the default only while the site has no release.
#
# The default version is what the site root redirects to. mike records it only
# as the root index.html that `mike set-default` writes, never in
# versions.json, so `mike list` cannot report it: its text output is
# `<version> [<aliases>]` per version and its `--json` output carries only
# version, title, aliases and, when a version has any, its properties (set
# with `mike props`), none of which is the default. An earlier guard looked for
# a `[default]` marker in `mike list` that mike never prints, so every develop
# deploy reset a released site's default to `dev` (issue #1214). The release is
# what decides instead: a site that has a version aliased `latest` has a
# release, and a develop deploy leaves its default alone.
#
# The logic lives here (not inline in action.yml) so it is testable:
# actions/cd/docs/deploy/tests/default.test.sh runs it with the real mike.
#
# Inputs (env): SCHEME, MIKE_CMD, MKDOCS_CMD, MKDOCS_CONFIG, DOC_VERSION,
# DOC_ALIAS (empty on a development deploy). MIKE_CMD and MKDOCS_CMD are
# commands that may carry a runner prefix ("uv run mike"), so they are expanded
# unquoted.
set -euo pipefail

error() {
  echo "::error::cd/docs/deploy: $*" >&2
  exit 1
}

for name in MIKE_CMD MKDOCS_CMD MKDOCS_CONFIG; do
  if [ -z "${!name:-}" ]; then
    error "$name is not set"
  fi
done

if [ "${SCHEME:-}" = "none" ]; then
  # Single-branch, un-versioned docs (versioning-scheme = none): publish one
  # plain site to the gh-pages root, with no mike version split, no
  # versions.json and no version selector. --force replaces the branch, so any
  # prior mike versions (dev/0.1/latest) are cleaned up on the next deploy.
  # Issue #713.
  $MKDOCS_CMD gh-deploy --config-file "$MKDOCS_CONFIG" --force
  exit 0
fi

if [ -z "${DOC_VERSION:-}" ]; then
  error "DOC_VERSION is not set"
fi

if [ -n "${DOC_ALIAS:-}" ]; then
  $MIKE_CMD deploy \
    -F "$MKDOCS_CONFIG" --push --update-aliases \
    "$DOC_VERSION" \
    "$DOC_ALIAS"
  $MIKE_CMD set-default \
    -F "$MKDOCS_CONFIG" --push latest
  exit 0
fi

$MIKE_CMD deploy -F "$MKDOCS_CONFIG" --push "$DOC_VERSION"

# Read the deployed versions as JSON, so a version title holding brackets
# cannot pass for an alias. A failure of `mike list` stops the deploy rather
# than reading as "no release", which would reset a released site's default.
if ! versions_json="$($MIKE_CMD list -F "$MKDOCS_CONFIG" --json)"; then
  error "mike list failed; not changing the site's default version"
fi
if ! released="$(printf '%s' "$versions_json" | python3 -c '
import json, sys
versions = json.load(sys.stdin)
if not isinstance(versions, list):
    sys.exit("mike list --json did not print a list of versions")
print("yes" if any("latest" in v["aliases"] for v in versions) else "no")
')"; then
  error "could not read the output of mike list --json"
fi

if [ "$released" = "yes" ]; then
  echo "The site has a release (a version aliased latest); leaving its default version unchanged."
else
  $MIKE_CMD set-default -F "$MKDOCS_CONFIG" --push "$DOC_VERSION"
fi
