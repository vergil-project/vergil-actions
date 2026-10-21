#!/usr/bin/env bash
#
# Publish step core for the registry-publish action (tests/publish.test.sh).
#
# Runs PUBLISH_CMD after checking the credential that vrg-ecosystem-resolve
# names in CREDENTIAL_SECRET. That name must be the env var the publish tool
# itself reads, and it must be one this action sets from a cd-release secret.
# A missing credential fails the step: a requested publish that cannot happen
# must not let the release report success (issue #980).
#
# Env:
#   PUBLISH_CMD        publish command (required)
#   CREDENTIAL_SECRET  credential env var name; empty when none is needed
#   <credential>       the credential itself, set by action.yml
set -eo pipefail

if [ -z "${PUBLISH_CMD:-}" ]; then
  echo "::error::registry-publish: no publish command to run"
  exit 1
fi

credential="${CREDENTIAL_SECRET:-}"

if [ -n "${credential}" ]; then
  # Env var the publish tool reads -> cd-release secret that feeds it.
  case "${credential}" in
    CARGO_REGISTRY_TOKEN) secret=CARGO_REGISTRY_TOKEN ;;
    MAVEN_GPG_PASSPHRASE) secret=GPG_PASSPHRASE ;;
    *)
      echo "::error::vrg-ecosystem-resolve names the credential ${credential}, which registry-publish does not provide (vergil-tooling and vergil-actions disagree on the credential name) — refusing to publish"
      exit 1
      ;;
  esac
  if [ -z "${!credential:-}" ]; then
    echo "::error::registry-publish is on but ${credential} is empty — set the ${secret} secret and pass it to cd-release, or turn registry-publish off"
    exit 1
  fi
fi

eval "${PUBLISH_CMD}"
