#!/usr/bin/env bash
#
# Print the `uv tool install` spec for vergil-tooling in a package build or
# install-test container (epic vergil-project/.github#356, spec §8.1).
#
#   * In vergil-tooling itself (pyproject.toml declares
#     name = "vergil-tooling"), print the repo directory, so CI exercises the
#     PR's own vrg-package rather than a released one.
#   * Otherwise print
#       vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@<ref>
#     where <ref> is [dependencies].vergil from vergil.toml.
#
# Usage: detect.sh [REPO_DIR]   (default: .)
#
# Reading vergil.toml needs a Python with tomllib (3.11+). Raw ubuntu/UBI images
# ship none, so it runs under uv's managed Python when uv is on PATH, else
# python3. A missing vergil.toml or [dependencies].vergil is fatal.
set -euo pipefail

repo="${1:-.}"

if grep -q '^name = "vergil-tooling"' "${repo}/pyproject.toml" 2>/dev/null; then
  printf '%s\n' "$repo"
  exit 0
fi

if [ ! -f "${repo}/vergil.toml" ]; then
  echo "detect.sh: ${repo}/vergil.toml not found" >&2
  exit 1
fi

read_ref='
import pathlib, sys, tomllib
cfg = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
ref = cfg.get("dependencies", {}).get("vergil", "")
if not isinstance(ref, str) or not ref:
    sys.exit(sys.argv[1] + ": [dependencies].vergil is missing or empty")
print(ref)
'

if command -v uv >/dev/null 2>&1; then
  ref="$(uv run --no-project --python 3.14 python -c "$read_ref" "${repo}/vergil.toml")"
else
  ref="$(python3 -c "$read_ref" "${repo}/vergil.toml")"
fi

printf 'vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@%s\n' "$ref"
