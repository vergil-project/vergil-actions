#!/usr/bin/env bash
# test-script-modes.test.sh — tests for validate-custom's test script
# mode check (#1201).
#
# Each case builds a scratch git repo with *.test.sh scripts staged at
# chosen modes, runs check_test_script_modes on it (sourced from
# scripts/bin/validate-custom) and asserts the exit status and the paths
# its errors name. Run from anywhere.
#
# Usage: bash scripts/tests/test-script-modes.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_CUSTOM="$SCRIPT_DIR/../bin/validate-custom"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# new_repo <name> — an empty scratch git repo. Prints its path.
new_repo() {
	local repo="$TMP/$1"
	mkdir -p "$repo"
	git -C "$repo" init --quiet
	printf '%s\n' "$repo"
}

# stage <repo> <path> <+x|-x> — write a script at <path> and stage it
# with the executable bit set or cleared.
stage() {
	mkdir -p "$(dirname "$1/$2")"
	printf '#!/bin/sh\nexit 0\n' >"$1/$2"
	git -C "$1" add -- "$2"
	git -C "$1" update-index --chmod="$3" -- "$2"
}

# run_case <name> <repo> <expected status> <expected error path>...
# Each expected path must appear on an ERROR line, and no other ERROR
# line may appear. A passing case may print no ERROR line; a failing case
# with no expected path asserts only its exit status.
run_case() {
	local name="$1" repo="$2" expect="$3" out rc path ok=1 errors
	shift 3
	out="$( (
		# shellcheck source=/dev/null
		source "$VALIDATE_CUSTOM"
		check_test_script_modes "$repo"
	) 2>&1)"
	rc=$?
	if [[ "$rc" -ne "$expect" ]]; then
		ok=0
	fi
	errors="$(grep -c '^ERROR:' <<<"$out" || true)"
	if [[ "$expect" -eq 0 && "$errors" -ne 0 ]]; then
		ok=0
	fi
	if [[ "$#" -gt 0 && "$errors" -ne "$#" ]]; then
		ok=0
	fi
	for path in "$@"; do
		if ! grep -qF "ERROR: $path: " <<<"$out"; then
			ok=0
		fi
	done
	if [[ "$ok" -eq 1 ]]; then
		pass=$((pass + 1))
		echo "PASS: $name"
	else
		fail=$((fail + 1))
		echo "FAIL: $name (exit $rc, expected $expect)"
		printf '%s\n' "$out" | sed 's/^/    /'
	fi
}

repo=$(new_repo exec)
stage "$repo" actions/a/tests/a.test.sh +x
stage "$repo" actions/b/c/tests/b.test.sh +x
run_case "executable test scripts pass" "$repo" 0

repo=$(new_repo nonexec)
stage "$repo" actions/a/tests/a.test.sh +x
stage "$repo" actions/b/tests/b.test.sh -x
run_case "a non-executable test script fails, naming it" "$repo" 1 \
	actions/b/tests/b.test.sh

repo=$(new_repo twobad)
stage "$repo" actions/a/tests/a.test.sh -x
stage "$repo" actions/b/c/tests/b.test.sh -x
stage "$repo" actions/c/tests/c.test.sh +x
run_case "every non-executable test script is named" "$repo" 1 \
	actions/a/tests/a.test.sh actions/b/c/tests/b.test.sh

repo=$(new_repo root-level)
stage "$repo" top.test.sh -x
run_case "a test script at the repo root is checked" "$repo" 1 \
	top.test.sh

repo=$(new_repo spaced)
stage "$repo" "actions/with space/tests/a.test.sh" -x
run_case "a path with a space is named whole" "$repo" 1 \
	"actions/with space/tests/a.test.sh"

repo=$(new_repo other-scripts)
stage "$repo" actions/a/tests/a.test.sh +x
stage "$repo" actions/a/helper.sh -x
stage "$repo" actions/a/tests/fixture.test.sh.txt -x
run_case "only *.test.sh scripts are checked" "$repo" 0

repo=$(new_repo disk-only)
stage "$repo" actions/a/tests/a.test.sh -x
chmod +x "$repo/actions/a/tests/a.test.sh"
run_case "the git mode is checked, not the mode on disk" "$repo" 1 \
	actions/a/tests/a.test.sh

repo=$(new_repo none)
stage "$repo" actions/a/helper.sh +x
run_case "a repo with no test scripts fails" "$repo" 1

repo="$TMP/not-a-repo"
mkdir -p "$repo"
run_case "a directory that is not a git repo fails" "$repo" 1

echo "test-script-modes: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
