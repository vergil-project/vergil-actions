#!/usr/bin/env bash
# test-suites-run.test.sh — tests for scripts/bin/check-test-suites-run,
# the check that every *.test.sh suite is run by a workflow or by
# validation (#1202).
#
# Each case builds a scratch git repo with chosen suites, workflows and
# validate-custom, runs the check on it and asserts the exit status and
# the paths its errors name. Run from anywhere.
#
# Usage: bash scripts/tests/test-suites-run.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../bin/check-test-suites-run"

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

# put <repo> <path> <content> — write <content> to <path> and stage it.
put() {
	mkdir -p "$(dirname "$1/$2")"
	printf '%s\n' "$3" >"$1/$2"
	git -C "$1" add -- "$2"
}

# suite <repo> <path> — a trivial staged suite at <path>.
suite() {
	put "$1" "$2" '#!/bin/sh
exit 0'
}

# workflow <repo> <name> <step lines> — a staged workflow
# .github/workflows/<name> whose one job's steps are <step lines>.
workflow() {
	put "$1" ".github/workflows/$2" "name: test
on: push
jobs:
  t:
    runs-on: ubuntu-24.04
    steps:
$3"
}

# run_case <name> <repo> <expected status> <expected error path>...
# Each expected path must appear on an ERROR line, and no other ERROR
# line may appear. A passing case may print no ERROR line; a failing case
# with no expected path asserts only its exit status.
run_case() {
	local name="$1" repo="$2" expect="$3" out rc path ok=1 errors
	shift 3
	out="$(bash "$CHECK" "$repo" 2>&1)"
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

repo=$(new_repo all-run)
suite "$repo" actions/a/tests/a.test.sh
suite "$repo" actions/b/c/tests/b.test.sh
workflow "$repo" smoke.yml '      - run: bash actions/a/tests/a.test.sh
      - name: b
        shell: bash
        run: bash actions/b/c/tests/b.test.sh'
run_case "suites run by a workflow pass" "$repo" 0

repo=$(new_repo unrun)
suite "$repo" actions/a/tests/a.test.sh
suite "$repo" actions/b/tests/b.test.sh
suite "$repo" actions/c/tests/c.test.sh
workflow "$repo" smoke.yml '      - run: bash actions/a/tests/a.test.sh'
run_case "every suite no workflow runs is named" "$repo" 1 \
	actions/b/tests/b.test.sh actions/c/tests/c.test.sh

repo=$(new_repo run-block)
suite "$repo" actions/a/tests/a.test.sh
suite "$repo" actions/b/tests/b.test.sh
workflow "$repo" smoke.yml '      - run: |
          set -euo pipefail
          bash actions/a/tests/a.test.sh
          cd x && sh actions/b/tests/b.test.sh'
run_case "suites run inside a run block pass" "$repo" 0

repo=$(new_repo direct)
suite "$repo" actions/a/tests/a.test.sh
suite "$repo" actions/b/tests/b.test.sh
suite "$repo" actions/c/tests/c.test.sh
workflow "$repo" smoke.yml '      - run: ./actions/a/tests/a.test.sh
      - run: bash ./actions/b/tests/b.test.sh
      - run: bash "actions/c/tests/c.test.sh"'
run_case "a suite run as ./path, bash ./path or a quoted path passes" "$repo" 0

repo=$(new_repo yaml-ext)
suite "$repo" actions/a/tests/a.test.sh
workflow "$repo" smoke.yaml '      - run: bash actions/a/tests/a.test.sh'
run_case "a .yaml workflow counts" "$repo" 0

repo=$(new_repo comment-only)
suite "$repo" actions/a/tests/a.test.sh
suite "$repo" actions/b/tests/b.test.sh
workflow "$repo" smoke.yml '      # bash actions/a/tests/a.test.sh
      - run: echo skipped # bash actions/b/tests/b.test.sh'
run_case "a suite named only in a comment fails" "$repo" 1 \
	actions/a/tests/a.test.sh actions/b/tests/b.test.sh

repo=$(new_repo named-not-run)
suite "$repo" actions/a/tests/a.test.sh
workflow "$repo" smoke.yml '      - run: cat actions/a/tests/a.test.sh'
run_case "a suite a workflow names but does not run fails" "$repo" 1 \
	actions/a/tests/a.test.sh

repo=$(new_repo outside-workflows)
suite "$repo" actions/a/tests/a.test.sh
workflow "$repo" smoke.yml '      - run: echo hi'
put "$repo" .github/workflows/README.md 'Run with: bash actions/a/tests/a.test.sh'
put "$repo" scripts/run-all.sh 'bash actions/a/tests/a.test.sh'
run_case "a suite run only outside a workflow fails" "$repo" 1 \
	actions/a/tests/a.test.sh

repo=$(new_repo untracked-workflow)
suite "$repo" actions/a/tests/a.test.sh
workflow "$repo" smoke.yml '      - run: echo hi'
mkdir -p "$repo/.github/workflows"
printf '      - run: bash actions/a/tests/a.test.sh\n' >"$repo/.github/workflows/local.yml"
run_case "an untracked workflow does not count" "$repo" 1 \
	actions/a/tests/a.test.sh

repo=$(new_repo whole-path)
suite "$repo" actions/a/tests/a.test.sh
suite "$repo" nested/actions/a/tests/a.test.sh
workflow "$repo" smoke.yml '      - run: bash actions/a/tests/a.test.sh
      - run: bash nested/actions/a/tests/a.test.sh.bak'
run_case "a suite counts only by its whole path" "$repo" 1 \
	nested/actions/a/tests/a.test.sh

repo=$(new_repo validate-custom)
suite "$repo" scripts/tests/x.test.sh
suite "$repo" scripts/tests/sub/y.test.sh
workflow "$repo" smoke.yml '      - run: echo hi'
put "$repo" scripts/bin/validate-custom 'for t in "$ROOT"/scripts/tests/*.test.sh; do bash "$t"; done'
run_case "validate-custom runs scripts/tests/ suites, not deeper ones" "$repo" 1 \
	scripts/tests/sub/y.test.sh

repo=$(new_repo no-validate-custom)
suite "$repo" scripts/tests/x.test.sh
workflow "$repo" smoke.yml '      - run: echo hi'
run_case "a scripts/tests/ suite fails with no validate-custom" "$repo" 1 \
	scripts/tests/x.test.sh

repo=$(new_repo validate-custom-comment)
suite "$repo" scripts/tests/x.test.sh
workflow "$repo" smoke.yml '      - run: echo hi'
put "$repo" scripts/bin/validate-custom '# for t in scripts/tests/*.test.sh; do bash "$t"; done'
run_case "a scripts/tests/ glob only in a validate-custom comment fails" "$repo" 1 \
	scripts/tests/x.test.sh

repo=$(new_repo spaced)
suite "$repo" "actions/with space/tests/a.test.sh"
workflow "$repo" smoke.yml '      - run: echo hi'
run_case "an unrun path with a space is named whole" "$repo" 1 \
	"actions/with space/tests/a.test.sh"

repo=$(new_repo no-suites)
workflow "$repo" smoke.yml '      - run: echo hi'
run_case "a repo with no suites fails" "$repo" 1

repo=$(new_repo no-workflows)
suite "$repo" actions/a/tests/a.test.sh
run_case "a repo with no workflows fails" "$repo" 1

repo="$TMP/not-a-repo"
mkdir -p "$repo"
run_case "a directory that is not a git repo fails" "$repo" 1

out="$(bash "$CHECK" 2>&1)"
rc=$?
if [[ "$rc" -eq 2 && "$out" == usage:* ]]; then
	pass=$((pass + 1))
	echo "PASS: no argument prints usage and exits 2"
else
	fail=$((fail + 1))
	echo "FAIL: no argument prints usage and exits 2 (exit $rc)"
	printf '%s\n' "$out" | sed 's/^/    /'
fi

echo "test-suites-run: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
