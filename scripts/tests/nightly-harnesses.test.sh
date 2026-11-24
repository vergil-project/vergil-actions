#!/usr/bin/env bash
# nightly-harnesses.test.sh — tests for scripts/bin/check-nightly-harnesses,
# the check that the nightly harness run calls every smoke workflow
# (vergil-project/vergil-actions#1399).
#
# Each case builds a scratch git repo with chosen workflows, runs the check
# on it and asserts the exit status and the workflow its errors name. Run
# from anywhere; needs yq (mikefarah v4).
#
# Usage: bash scripts/tests/nightly-harnesses.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../bin/check-nightly-harnesses"
NIGHTLY=".github/workflows/nightly-harnesses.yml"

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

# smoke <repo> <name> [<triggers>] — a staged smoke-<name>.yml whose `on:`
# holds <triggers> (default: workflow_call, workflow_dispatch).
smoke() {
	local triggers="${3:-  workflow_call:
  workflow_dispatch:}"
	put "$1" ".github/workflows/smoke-$2.yml" "name: smoke $2
on:
$triggers
jobs:
  fixtures:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi"
}

# nightly <repo> <jobs text> [<triggers>] — a staged nightly-harnesses.yml
# holding <jobs text> under `jobs:` (default triggers: schedule and
# workflow_dispatch).
nightly() {
	local triggers="${3:-  schedule:
    - cron: '15 5 * * *'
  workflow_dispatch:}"
	put "$1" "$NIGHTLY" "name: nightly
on:
$triggers
jobs:
$2"
}

# call <name> — one nightly job calling smoke-<name>.yml.
call() {
	printf '  %s:\n    uses: ./.github/workflows/smoke-%s.yml\n' "$1" "$1"
}

# result <name> <ok> <detail> — record one case.
result() {
	if [[ "$2" -eq 1 ]]; then
		pass=$((pass + 1))
		echo "PASS: $1"
	else
		fail=$((fail + 1))
		echo "FAIL: $1"
		printf '%s\n' "$3"
	fi
}

# run_case <name> <repo> <expected status> <expected error substring>...
# Each substring must appear on an ERROR line, and there must be exactly as
# many ERROR lines as substrings.
run_case() {
	local name="$1" repo="$2" expect="$3" out rc want ok=1 errors
	shift 3
	out="$(bash "$CHECK" "$repo" 2>&1)"
	rc=$?
	[[ "$rc" -eq "$expect" ]] || ok=0
	errors="$(grep -c '^ERROR: ' <<<"$out" || true)"
	[[ "$errors" -eq "$#" ]] || ok=0
	for want in "$@"; do
		grep -qF -- "$want" <<<"$(grep '^ERROR: ' <<<"$out")" || ok=0
	done
	result "$name (exit $rc, expected $expect)" "$ok" "$out"
}

repo=$(new_repo ok)
smoke "$repo" alpha
smoke "$repo" beta
nightly "$repo" "$(call alpha)
$(call beta)
  report:
    needs: [alpha, beta]
    if: always()
    runs-on: ubuntu-24.04
    steps:
      - run: echo report"
run_case "every smoke workflow called, with the report job beside them, passes" "$repo" 0

repo=$(new_repo missing-call)
smoke "$repo" alpha
smoke "$repo" beta
nightly "$repo" "$(call alpha)"
run_case "a smoke workflow the nightly run does not call is named" "$repo" 1 \
	"$NIGHTLY: no job beta calling ./.github/workflows/smoke-beta.yml (found uses: <none>)"

repo=$(new_repo no-workflow-call)
smoke "$repo" alpha "  workflow_dispatch:
  pull_request:"
nightly "$repo" "$(call alpha)"
run_case "a smoke workflow with no workflow_call trigger is named" "$repo" 1 \
	".github/workflows/smoke-alpha.yml: its on: has no workflow_call trigger"

repo=$(new_repo wrong-key)
smoke "$repo" alpha
nightly "$repo" "  first:
    uses: ./.github/workflows/smoke-alpha.yml"
run_case "a call under another job key is named both ways" "$repo" 1 \
	"$NIGHTLY: no job alpha calling" \
	"$NIGHTLY: job first calls ./.github/workflows/smoke-alpha.yml, which is not a tracked smoke-first.yml"

repo=$(new_repo stale-call)
smoke "$repo" alpha
nightly "$repo" "$(call alpha)
$(call gone)"
run_case "a call to a smoke workflow that no longer exists is named" "$repo" 1 \
	"$NIGHTLY: job gone calls ./.github/workflows/smoke-gone.yml"

repo=$(new_repo remote-call)
smoke "$repo" alpha
nightly "$repo" "  alpha:
    uses: vergil-project/vergil-actions/.github/workflows/smoke-alpha.yml@v2.1"
run_case "a call to another ref of the smoke workflow is named" "$repo" 1 \
	"$NIGHTLY: no job alpha calling ./.github/workflows/smoke-alpha.yml (found uses: vergil-project/"

repo=$(new_repo no-schedule)
smoke "$repo" alpha
nightly "$repo" "$(call alpha)" "  workflow_dispatch:"
run_case "a nightly run with no schedule is named" "$repo" 1 \
	"$NIGHTLY: its on: has no schedule trigger"

repo=$(new_repo no-dispatch)
smoke "$repo" alpha
nightly "$repo" "$(call alpha)" "  schedule:
    - cron: '15 5 * * *'"
run_case "a nightly run with no manual trigger is named" "$repo" 1 \
	"$NIGHTLY: its on: has no workflow_dispatch trigger"

repo=$(new_repo no-nightly)
smoke "$repo" alpha
run_case "a missing nightly workflow fails the check" "$repo" 1 \
	"$NIGHTLY: not tracked in git"

repo=$(new_repo untracked-nightly)
smoke "$repo" alpha
mkdir -p "$repo/.github/workflows"
printf 'name: x\non:\n  schedule:\n  workflow_dispatch:\njobs:\n%s\n' "$(call alpha)" >"$repo/$NIGHTLY"
run_case "an untracked nightly workflow does not count" "$repo" 1 \
	"$NIGHTLY: not tracked in git"

repo=$(new_repo malformed)
smoke "$repo" alpha
put "$repo" .github/workflows/smoke-beta.yml "name: x
jobs: [unclosed"
nightly "$repo" "$(call alpha)
$(call beta)"
run_case "a smoke workflow that does not parse fails the check" "$repo" 1 \
	".github/workflows/smoke-beta.yml: missing from the working tree or does not parse"

repo=$(new_repo no-smokes)
nightly "$repo" "  report:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi"
run_case "a repo with no smoke workflows fails the check" "$repo" 1 \
	"no .github/workflows/smoke-*.yml workflows are tracked in git"

repo=$(new_repo untracked-smoke)
smoke "$repo" alpha
nightly "$repo" "$(call alpha)"
printf 'name: x\non:\n  pull_request:\njobs: {}\n' >"$repo/.github/workflows/smoke-draft.yml"
run_case "an untracked smoke workflow is not read" "$repo" 0

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
