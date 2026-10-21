#!/usr/bin/env bash
#
# Print the vergil-tooling tag a consuming repo pins in vergil.toml
# (`[dependencies].vergil`, e.g. `v2.1`) on stdout, for the setup action's
# `uv tool install` step.
#
# Every way the pin can be absent or unusable — no vergil.toml, a file that is
# not valid TOML, no [dependencies] table, no `vergil` key, an empty or
# non-string value — fails with one `::error::` annotation on stderr that names
# the file or key and says what to add, and a non-zero exit. Nothing is printed
# on stdout in that case, so the caller never installs from an empty tag
# (issue #977: these used to crash with a Python traceback).
#
# The logic lives here (not inline in action.yml) so it is unit-testable
# (tests/read-pin.test.sh), mirroring derive.sh.
#
# vergil.toml is read from $VERGIL_CONFIG_DIR (default: the current directory,
# i.e. the checked-out consumer repo at the workspace root). The override lets
# the test harness point the reader at fixture repos.
set -euo pipefail

config_dir="${VERGIL_CONFIG_DIR:-.}"

python3 - "$config_dir" <<'PY'
import pathlib
import sys
import tomllib

EXAMPLE = 'add it under [dependencies] as: vergil = "v2.1"'


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


path = pathlib.Path(sys.argv[1]) / "vergil.toml"
try:
    text = path.read_text()
except FileNotFoundError:
    fail(
        f"vergil.toml not found at {path}; it pins the vergil-tooling version "
        "to install. Create vergil.toml at the repository root (check out the "
        "repository before this action) with a [dependencies] table holding "
        'vergil = "v2.1"'
    )

try:
    cfg = tomllib.loads(text)
except tomllib.TOMLDecodeError as exc:
    fail(f"{path} is not valid TOML: {exc}")

deps = cfg.get("dependencies")
if deps is None:
    fail(
        f"{path} is missing [dependencies].vergil, the vergil-tooling version "
        f"to install; {EXAMPLE}"
    )
if not isinstance(deps, dict):
    fail(f"[dependencies] in {path} must be a table; {EXAMPLE}")

tag = deps.get("vergil")
if tag is None:
    fail(
        f"{path} is missing [dependencies].vergil, the vergil-tooling version "
        f"to install; {EXAMPLE}"
    )
if not isinstance(tag, str):
    fail(
        f"[dependencies].vergil in {path} must be a string tag, got "
        f"{type(tag).__name__}; {EXAMPLE}"
    )
if not tag.strip():
    fail(
        f"[dependencies].vergil in {path} is empty; set it to a vergil-tooling "
        f'tag, e.g. vergil = "v2.1"'
    )

print(tag)
PY
