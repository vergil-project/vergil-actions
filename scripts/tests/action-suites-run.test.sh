#!/usr/bin/env bash
# action-suites-run.test.sh — tests for validate-custom's run of the
# action test suites (#1108).
#
# Each case builds a scratch git repo with actions/**/tests/*.test.sh
# suites that pass, fail or record where they ran, runs run_action_suites
# on it (sourced from scripts/bin/validate-custom, with the case's own
# CI_ONLY_ACTION_SUITES) and asserts the exit status, the paths its errors
# name and which suites ran. Run from anywhere.
#
# Usage: bash scripts/tests/action-suites-run.test.sh
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

# suite <repo> <path> <pass|fail> — stage a suite at <path> that prints
# "RAN <path> IN <its working directory>" and exits 0 or 1.
suite() {
	local rc=0
	[[ "$3" == fail ]] && rc=1
	mkdir -p "$(dirname "$1/$2")"
	# shellcheck disable=SC2016 # fixture suite content; the $ is meant literally
	printf '#!/usr/bin/env bash\necho "RAN %s IN $PWD"\nexit %d\n' "$2" "$rc" >"$1/$2"
	git -C "$1" add -- "$2"
}

# run_case <name> <repo> <expected status> <expected error path>... --
# <expected ran path>... — CI_ONLY holds the case's CI-only entries. Each
# expected error path must appear on an ERROR line and no other ERROR line
# may appear; exactly the expected ran paths must have run, each from the
# repo root.
CI_ONLY=()
run_case() {
	local name="$1" repo="$2" expect="$3" out rc path ok=1 errors want_errors=0 ran
	shift 3
	local error_paths=() ran_paths=()
	while [[ "$#" -gt 0 && "$1" != -- ]]; do
		error_paths+=("$1")
		shift
	done
	[[ "${1:-}" == -- ]] && shift
	ran_paths=("$@")
	out="$( (
		# shellcheck source=/dev/null
		source "$VALIDATE_CUSTOM"
		# shellcheck disable=SC2034 # read by run_action_suites, sourced above
		CI_ONLY_ACTION_SUITES=("${CI_ONLY[@]}")
		run_action_suites "$repo"
	) 2>&1)"
	rc=$?
	[[ "$rc" -ne "$expect" ]] && ok=0
	errors="$(grep -c '^ERROR:' <<<"$out" || true)"
	want_errors="${#error_paths[@]}"
	if [[ "$expect" -eq 0 && "$errors" -ne 0 ]]; then
		ok=0
	fi
	if [[ "$want_errors" -gt 0 && "$errors" -ne "$want_errors" ]]; then
		ok=0
	fi
	for path in "${error_paths[@]}"; do
		grep -qF "ERROR: $path: " <<<"$out" || ok=0
	done
	ran="$(grep -c '^RAN ' <<<"$out" || true)"
	[[ "$ran" -ne "${#ran_paths[@]}" ]] && ok=0
	for path in "${ran_paths[@]}"; do
		grep -qxF "RAN $path IN $repo" <<<"$out" || ok=0
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

repo=$(new_repo passing)
suite "$repo" actions/a/tests/a.test.sh pass
suite "$repo" actions/b/c/tests/b.test.sh pass
CI_ONLY=()
run_case "every action suite runs, from the repo root" "$repo" 0 -- \
	actions/a/tests/a.test.sh actions/b/c/tests/b.test.sh

repo=$(new_repo failing)
suite "$repo" actions/a/tests/a.test.sh pass
suite "$repo" actions/b/tests/b.test.sh fail
suite "$repo" actions/c/tests/c.test.sh pass
CI_ONLY=()
run_case "a failing suite fails, naming it, and the rest still run" "$repo" 1 \
	actions/b/tests/b.test.sh -- \
	actions/a/tests/a.test.sh actions/b/tests/b.test.sh actions/c/tests/c.test.sh

repo=$(new_repo ci-only)
suite "$repo" actions/a/tests/a.test.sh pass
suite "$repo" actions/b/tests/live.test.sh fail
CI_ONLY=("actions/b/tests/live.test.sh|live suite")
run_case "a CI-only suite is not run" "$repo" 0 -- \
	actions/a/tests/a.test.sh

repo=$(new_repo stale)
suite "$repo" actions/a/tests/a.test.sh pass
CI_ONLY=("actions/gone/tests/gone.test.sh|live suite")
run_case "a CI-only entry naming no tracked suite fails, naming it" "$repo" 1 \
	actions/gone/tests/gone.test.sh -- \
	actions/a/tests/a.test.sh

repo=$(new_repo elsewhere)
suite "$repo" actions/a/tests/a.test.sh pass
suite "$repo" actions/a/helper.test.sh fail
suite "$repo" actions/a/tests/deeper/d.test.sh fail
suite "$repo" scripts/tests/s.test.sh fail
suite "$repo" top.test.sh fail
CI_ONLY=()
run_case "only suites directly in an actions/**/tests/ directory run" "$repo" 0 -- \
	actions/a/tests/a.test.sh

repo=$(new_repo untracked)
suite "$repo" actions/a/tests/a.test.sh pass
mkdir -p "$repo/actions/b/tests"
printf '#!/bin/sh\nexit 1\n' >"$repo/actions/b/tests/b.test.sh"
CI_ONLY=()
run_case "an untracked suite is not run" "$repo" 0 -- \
	actions/a/tests/a.test.sh

repo=$(new_repo spaced)
suite "$repo" "actions/with space/tests/a.test.sh" fail
CI_ONLY=()
run_case "a failing path with a space is named whole" "$repo" 1 \
	"actions/with space/tests/a.test.sh" -- \
	"actions/with space/tests/a.test.sh"

repo=$(new_repo all-ci-only)
suite "$repo" actions/a/tests/a.test.sh pass
CI_ONLY=("actions/a/tests/a.test.sh|live suite")
run_case "a repo whose every suite is CI-only fails" "$repo" 1 --

repo=$(new_repo none)
suite "$repo" scripts/tests/s.test.sh pass
CI_ONLY=()
run_case "a repo with no action suites fails" "$repo" 1 --

repo="$TMP/not-a-repo"
mkdir -p "$repo"
CI_ONLY=()
run_case "a directory that is not a git repo fails" "$repo" 1 --

echo "action-suites-run: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
