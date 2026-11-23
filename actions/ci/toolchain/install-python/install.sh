#!/usr/bin/env bash
#
# Install a Python CI leg's dev dependencies, or skip the install, loudly, on
# a repo not bootstrapped yet (issue #1206).
#
# A Python repo is bootstrapped by two manifests, pyproject.toml and uv.lock.
# vrg-validate (vergil-tooling#4384) skips its language stages, with a
# notice and a warning, only when every one of them is missing, as in a
# freshly initialised repo. This step uses the same test, so PR CI reaches
# vrg-validate and its loud skip instead of failing here first:
#
#   neither file   — print a ::notice:: naming both and exit 0. The leg's
#                    vrg-validate then skips its stages, or fails the leg when
#                    the repo has Python sources but no manifest.
#   either or both — run `uv sync --group dev --frozen`. A partial bootstrap
#                    (pyproject.toml with no uv.lock, say) is not skipped: uv
#                    fails on it, and so does this step. Any uv failure is the
#                    step's failure.
#
# The files are looked up in the working directory, the checkout. The caller
# pins uv's interpreter (ci/toolchain/pin-python) before this runs; the source
# pin is repeated on the uv command so it holds whoever calls this.
set -euo pipefail

if [ ! -f pyproject.toml ] && [ ! -f uv.lock ]; then
  echo "::notice title=install-python::skipped: no pyproject.toml, uv.lock" \
    "(python repo not bootstrapped yet); add them to install the dev dependencies"
  exit 0
fi

UV_PYTHON_PREFERENCE=only-system uv sync --group dev --frozen
