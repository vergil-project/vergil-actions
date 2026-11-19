#!/usr/bin/env bash
#
# Print the `uv tool install` spec for the driver vergil-tooling in a package
# build or install-test container (epic vergil-project/.github#356, spec
# §8.1), and write the constraints it installs with (epic
# vergil-project/.github#1350, spec §4.2).
#
#   * In vergil-tooling itself (pyproject.toml declares
#     name = "vergil-tooling"), print the repo directory, so CI exercises the
#     PR's own vrg-package rather than a released one. No constraints file.
#   * Otherwise read <ref>, [dependencies].vergil from vergil.toml:
#       - a line pin vX.Y resolves to the newest vX.Y.Z tag, never the moving
#         vX.Y tag; an exact pin vX.Y.Z is that tag. Either way the tag
#         resolves to its commit SHA exactly once, with one `git ls-remote`
#         (the peeled ^{} entry: release tags are annotated, and the tag
#         object's own SHA is not the commit). The spec is
#           vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@<sha>
#         and CONSTRAINTS_FILE gets that commit's uv.lock, exported from a
#         shallow fetch of the commit (over git, never a raw-content URL).
#         Code, lock and log all name the one SHA.
#       - any other ref is a dev ref: the spec names it as written, and no
#         constraints file is written (dev refs install unconstrained).
#
# Usage: VRG_DRIVER_PYTHON=<version> detect.sh REPO_DIR CONSTRAINTS_FILE
#
# CONSTRAINTS_FILE must not exist beforehand; detect.sh creates it only for a
# released ref, so the caller passes `--constraints` exactly when it exists.
# Every failure (no tag on the line, a failed ls-remote, fetch or export, a
# commit with no uv.lock, a lock export that names the project) exits nonzero
# with a named error and prints nothing on stdout: there is no unconstrained
# or older fallback.
#
# VRG_DRIVER_PYTHON is the driver vergil-tooling's Python version. The setup
# action sets it from its `python` input, the only place the version is
# written. Unset or empty is fatal; there is no default.
#
# Reading vergil.toml needs a Python with tomllib (3.11+). Raw ubuntu/UBI images
# ship none, so it runs under uv's managed VRG_DRIVER_PYTHON when uv is on
# PATH, else python3. A missing vergil.toml or [dependencies].vergil is fatal.
#
# --no-config stops uv reading the repo's uv settings ([tool.uv] in
# pyproject.toml, uv.toml), which --no-project does not. A repo may set
# python-downloads = "manual" or python-preference = "only-managed"; honoured
# here, those would stop uv downloading the interpreter these images need, or
# change which one it picks (issue #1003). Reading vergil.toml never runs the
# repo's code, so its uv settings have no say in this interpreter. The lock
# export passes it too: a --frozen export reads only the lock, so the result
# is the same, and no config file on the runner can change it.
set -euo pipefail

GIT_URL="https://github.com/vergil-project/vergil-tooling"

die() {
  printf 'detect.sh: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'detect.sh: %s\n' "$*" >&2
}

if [ -z "${VRG_DRIVER_PYTHON:-}" ]; then
  die "VRG_DRIVER_PYTHON must be set"
fi

[ "$#" -eq 2 ] || die "usage: detect.sh REPO_DIR CONSTRAINTS_FILE"
repo="$1"
constraints="$2"
[ -n "$constraints" ] || die "CONSTRAINTS_FILE must not be empty"
[ ! -e "$constraints" ] && [ ! -L "$constraints" ] ||
  die "${constraints} already exists; pass a path that does not"
case "$constraints" in
  /*) ;;
  *) constraints="${PWD}/${constraints}" ;;
esac

if grep -q '^name = "vergil-tooling"' "${repo}/pyproject.toml" 2>/dev/null; then
  log "the repo is vergil-tooling itself; installing its checkout"
  printf '%s\n' "$repo"
  exit 0
fi

if [ ! -f "${repo}/vergil.toml" ]; then
  die "${repo}/vergil.toml not found"
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
  ref="$(uv run --no-config --no-project --python "$VRG_DRIVER_PYTHON" python -c "$read_ref" "${repo}/vergil.toml")"
else
  ref="$(python3 -c "$read_ref" "${repo}/vergil.toml")"
fi

# tag_commit <ls-remote output> <tag>: the commit SHA <tag> names. An
# annotated tag's peeled ^{} entry is its commit; a lightweight tag has none,
# and its own entry is the commit.
tag_commit() {
  local refs="$1" tag="$2" sha
  sha="$(printf '%s\n' "$refs" | awk -v r="refs/tags/${tag}^{}" '$2 == r { print $1 }')"
  if [ -z "$sha" ]; then
    sha="$(printf '%s\n' "$refs" | awk -v r="refs/tags/${tag}" '$2 == r { print $1 }')"
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "no commit SHA for ${tag} in ${GIT_URL}"
  printf '%s\n' "$sha"
}

# export_constraints <sha>: write <sha>'s uv.lock, as third-party pins only,
# to $constraints.
export_constraints() {
  local sha="$1" src
  src="$(mktemp -d)"
  if ! git -C "$src" init -q ||
    ! git -C "$src" fetch -q --depth 1 "$GIT_URL" "$sha" ||
    ! git -C "$src" checkout -q FETCH_HEAD; then
    rm -rf "$src"
    die "could not fetch commit ${sha} of ${GIT_URL} to read its uv.lock"
  fi
  if [ ! -f "${src}/uv.lock" ]; then
    rm -rf "$src"
    die "commit ${sha} of ${GIT_URL} has no uv.lock"
  fi
  if ! (cd "$src" && uv export --no-config --frozen --no-dev --no-emit-project --no-hashes \
    --format requirements-txt -o "$constraints" >/dev/null); then
    rm -rf "$src" "$constraints"
    die "exporting the uv.lock of commit ${sha} failed"
  fi
  rm -rf "$src"
  [ -f "$constraints" ] || die "exporting the uv.lock of commit ${sha} wrote no ${constraints}"
  # Constraints name third-party pins only: never the project, nor an editable
  # or path line, which uv tool install would reject or install from.
  if grep -Eq '^[[:space:]]*(-e[[:space:]]|--editable|\.|/|vergil-tooling([^[:alnum:]_.-]|$))' "$constraints"; then
    rm -f "$constraints"
    die "the uv.lock export of commit ${sha} names the project or a path; refusing it as constraints"
  fi
}

tag=""
if [[ "$ref" =~ ^v[0-9]+\.[0-9]+$ ]]; then
  refs="$(git ls-remote --tags "$GIT_URL" "refs/tags/${ref}.*")" ||
    die "could not list the ${ref}.* tags of ${GIT_URL}"
  tag="$(printf '%s\n' "$refs" |
    sed -n "s#^[0-9a-f]*[[:space:]]*refs/tags/\(${ref//./\\.}\.[0-9][0-9]*\)\$#\1#p" |
    sort -t. -k3,3n | tail -n 1)"
  [ -n "$tag" ] || die "no ${ref}.Z release tag in ${GIT_URL}"
elif [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  tag="$ref"
  refs="$(git ls-remote --tags "$GIT_URL" "refs/tags/${tag}" "refs/tags/${tag}^{}")" ||
    die "could not list the ${tag} tag of ${GIT_URL}"
fi

if [ -z "$tag" ]; then
  log "dev ref ${ref}: installing it as written, unconstrained"
  printf 'vergil-tooling @ git+%s@%s\n' "$GIT_URL" "$ref"
  exit 0
fi

sha="$(tag_commit "$refs" "$tag")"
log "${ref} resolves to ${tag} at ${sha}"
export_constraints "$sha"
log "constraints: the uv.lock of ${tag} (${sha})"
printf 'vergil-tooling @ git+%s@%s\n' "$GIT_URL" "$sha"
