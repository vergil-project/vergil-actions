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

# CI parity (epic vergil-project/.github#291): expose NODE_PATH so a node library
# baked out-of-workspace by the build-command (npm install -g …) resolves via
# CommonJS require in the subsequent test steps — mirroring the local dev-image
# NODE_PATH injection (vergil-project/vergil-tooling#2781). Use `npm root -g`
# (= /usr/lib/node_modules on the vergil base images) so local and CI use the
# identical value. Guarded on CI context ($GITHUB_ENV) and npm presence, so a
# non-CI or non-node run is a clean no-op. NODE_PATH is honoured by require only;
# ESM import ignores it (documented limitation).
if [ -n "${GITHUB_ENV:-}" ] && command -v npm >/dev/null 2>&1; then
  echo "NODE_PATH=$(npm root -g)" >>"${GITHUB_ENV}"
fi
