#!/usr/bin/env bash
#
# Derive the CI version set for a reusable CI workflow from vergil.toml.
#
# Emits three values to $GITHUB_OUTPUT:
#
#   versions             — the `[ci].versions` list as a compact JSON array
#                          string, consumed by the `matrix` job to fan out
#                          per-version legs.
#   primary-version      — the single "primary" version consumed by
#                          single-container jobs (ci-security, ci-version-bump,
#                          ci-docs) and as the container tag for run-once kinds.
#   primary-container-tag — the family-routed container tag of the primary
#                          version: for family-on-token languages (cpp, ts) the
#                          numeric part after the family prefix (clang-20 -> 20);
#                          every other language keeps the version verbatim
#                          (3.14 -> 3.14, latest -> latest). This mirrors the
#                          per-version routing in actions/ci/matrix/resolve.sh
#                          (the single source of truth for the split) so the
#                          single-container jobs `common` (ci-quality) and
#                          `version-bump` (ci-version-bump) resolve the same
#                          image tag the matrix legs do — prod-cpp-clang:20, not
#                          the nonexistent prod-cpp-clang:clang-20 (issue #893).
#                          The compiler/runtime family itself rides
#                          container-suffix (cpp-clang / ts-node), so only the
#                          tag is routed here. LANGUAGE is supplied by the
#                          calling workflow's `inputs.language` via the setup
#                          action; when empty the tag falls through verbatim.
#
# primary-version derivation (mirrors the tooling side so both agree):
#
#   * If `[ci].primary-version` is set explicitly, it wins verbatim — the
#     documented escape hatch for when "primary" must NOT be the max.
#   * Otherwise it is the highest version in `[ci].versions` by a natural
#     ("semantic") sort — `3.14` from `["3.12","3.13","3.14"]` — robust to list
#     order. Numeric runs compare numerically (so `clang-20` > `clang-9`).
#
# The logic lives here (not inline in action.yml) so it is unit-testable
# (tests/derive.test.sh), mirroring the sibling matrix action's resolve.sh.
#
# vergil.toml is read from $VERGIL_CONFIG_DIR (default: the current directory,
# i.e. the checked-out consumer repo at the workspace root). The override lets
# the test harness point the resolver at fixture repos.
set -euo pipefail

config_dir="${VERGIL_CONFIG_DIR:-.}"

python3 - "$config_dir" <<'PY' >>"$GITHUB_OUTPUT"
import json
import os
import pathlib
import re
import sys
import tomllib

config_dir = pathlib.Path(sys.argv[1])
cfg = tomllib.loads((config_dir / "vergil.toml").read_text())

# The calling workflow's `inputs.language` (plumbed in as $LANGUAGE by the setup
# action). Empty when the setup action is invoked without it, in which case the
# container tag falls through to the verbatim version.
language = os.environ.get("LANGUAGE", "")

ci = cfg.get("ci")
if not isinstance(ci, dict):
    print("::error::vergil.toml is missing the required [ci] section", file=sys.stderr)
    sys.exit(1)

versions = ci.get("versions")
if not isinstance(versions, list) or not versions or not all(
    isinstance(v, str) for v in versions
):
    print(
        "::error::[ci].versions must be a non-empty list of strings",
        file=sys.stderr,
    )
    sys.exit(1)


def natural_key(value: str) -> list[object]:
    """Natural-sort key: numeric runs compare as ints, text as text.

    ``3.14`` -> ``['', 3, '.', 14, '']`` so ``3.14 > 3.13`` and
    ``clang-20 > clang-9`` (20 > 9, not lexical). re.split alternates
    text/number segments, so aligned positions across versions share a type.
    """
    return [int(tok) if tok.isdigit() else tok for tok in re.split(r"(\d+)", value)]


explicit = ci.get("primary-version")
if explicit is not None:
    if not isinstance(explicit, str) or not explicit.strip():
        print(
            "::error::[ci].primary-version must be a non-empty string",
            file=sys.stderr,
        )
        sys.exit(1)
    primary = explicit
else:
    primary = max(versions, key=natural_key)

# Family-routed container tag of the primary version. For the family-on-token
# languages the version carries the compiler/runtime family (clang-20, gcc-14,
# node-24); the image tag is the part after the family prefix while the family
# rides container-suffix, so split on "-" and keep the remainder — exactly as
# actions/ci/matrix/resolve.sh routes the per-version matrix legs (the single
# source of truth). Every other language keeps the version verbatim.
if language in ("cpp", "typescript"):
    primary_container_tag = "-".join(primary.split("-")[1:])
else:
    primary_container_tag = primary

print("versions=" + json.dumps(versions, separators=(",", ":")))
print("primary-version=" + primary)
print("primary-container-tag=" + primary_container_tag)
PY
