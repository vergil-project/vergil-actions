#!/usr/bin/env bash
#
# Pin uv to a CI leg's Python interpreter (epic vergil-project/.github#407,
# spec §6.5).
#
# Writes two variables to $GITHUB_ENV so every later step in the leg sees them:
#
#   UV_PYTHON=<version>            — the version: the leg's resolved x.y, not
#                                    one a repo file (.python-version) selects.
#   UV_PYTHON_PREFERENCE=only-system — the source: the image's interpreter.
#                                    A repo may set uv's `python-preference`
#                                    (e.g. `only-managed` for a lab VM); without
#                                    this, uv would download its own managed
#                                    Python and the leg would pass on an
#                                    interpreter the image never provided. With
#                                    it, a missing interpreter fails loudly.
#
# The environment variables take precedence over the repo's uv settings.
#
# Inputs (env): VERSION (the leg's resolved version, x.y), GITHUB_ENV.
set -euo pipefail

version="${VERSION:-}"

error() {
  echo "::error::$*" >&2
  exit 1
}

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  error "pin-python: version must be an x.y Python version (got '${version}')"
fi
if [ -z "${GITHUB_ENV:-}" ]; then
  error "pin-python: GITHUB_ENV is not set; cannot export the uv pin"
fi

{
  echo "UV_PYTHON=${version}"
  echo "UV_PYTHON_PREFERENCE=only-system"
} >>"$GITHUB_ENV"
echo "pin-python: UV_PYTHON=${version} UV_PYTHON_PREFERENCE=only-system"
