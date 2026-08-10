#!/usr/bin/env bash
#
# Install the Debian packages a repo declares in [container].system-packages.
#
# Reads the apt install snippet from `vrg-container-system-packages
# --install-script` — the single speller shared with the local dev-container
# cache build (epic vergil-project/.github#272) — and runs it with a bounded
# retry so a transient mirror flake does not fail the job. Fail-closed: a
# genuinely missing candidate exhausts the retries and exits non-zero with the
# speller's own "not installable" (package + platform) message still visible;
# nothing is silently skipped.
#
# Test-runtime dependency: callers wire this onto jobs that execute the repo's
# tests only, never onto lint/typecheck jobs (spec §3.3).
#
# Tunables (env, for tests): SYSTEM_PACKAGES_ATTEMPTS (default 3),
# SYSTEM_PACKAGES_RETRY_DELAY seconds between attempts (default 5).
set -euo pipefail

attempts="${SYSTEM_PACKAGES_ATTEMPTS:-3}"
delay="${SYSTEM_PACKAGES_RETRY_DELAY:-5}"

script="$(vrg-container-system-packages --install-script)"
if [ -z "${script}" ]; then
  echo "No [container].system-packages declared; skipping."
  exit 0
fi

for i in $(seq 1 "${attempts}"); do
  if bash -c "${script}"; then
    exit 0
  fi
  echo "system-package install attempt ${i}/${attempts} failed" >&2
  if [ "${i}" -lt "${attempts}" ]; then
    sleep "${delay}"
  fi
done

echo "::error::system-package install failed after ${attempts} attempts" >&2
exit 1
