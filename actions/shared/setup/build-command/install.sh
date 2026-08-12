#!/usr/bin/env bash
#
# Run the command a repo declares in [container].build-command.
#
# Reads it from `vrg-container-build-command --script` — the single speller
# shared with the local dev-container cache build (epic vergil-project/.github#291).
# Fail-closed and NOT retried: unlike apt (mirror flake), an arbitrary build
# command that fails is a real failure, not a transient one.
#
# Test-runtime dependency: callers wire this onto jobs that execute the repo's
# tests only, never lint/typecheck (spec §3.3). Runs after Install vergil-tooling.
set -euo pipefail

script="$(vrg-container-build-command --script)"
if [ -z "${script}" ]; then
  echo "No [container].build-command declared; skipping."
  exit 0
fi

echo "Running [container].build-command: ${script}"
bash -c "${script}"
