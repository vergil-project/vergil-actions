#!/usr/bin/env bash
# early-exit-pipes.test.sh — tests for scripts/bin/check-early-exit-pipes,
# the check that no pipeline feeds an early-exit consumer such as
# `grep -q` or `head` (#1325).
#
# Each case builds a scratch git repo with chosen files, runs the check on
# it and asserts the exit status and the file:line its errors name. The
# pipes in the fixtures are written as ${P} so this file does not trip
# the check itself. Run from anywhere.
#
# Usage: bash scripts/tests/early-exit-pipes.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../bin/check-early-exit-pipes"
P='|'

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

# run_case <name> <repo> <expected status> <expected file:line>...
# Each expected file:line must appear on an ERROR line, and no other
# file:line may.
run_case() {
	local name="$1" repo="$2" expect="$3" out rc loc ok=1 errors
	shift 3
	out="$(bash "$CHECK" "$repo" 2>&1)"
	rc=$?
	[[ "$rc" -eq "$expect" ]] || ok=0
	errors="$(grep -c '^ERROR: [^ ]*:[0-9]*: ' <<<"$out" || true)"
	[[ "$errors" -eq "$#" ]] || ok=0
	for loc in "$@"; do
		grep -qF "ERROR: $loc: " <<<"$out" || ok=0
	done
	result "$name (exit $rc, expected $expect)" "$ok" "$out"
}

repo=$(new_repo flagged)
put "$repo" a.sh "x=1
if cmd ${P} grep -q y; then :; fi"
put "$repo" b.sh "cmd ${P} grep -qx setup"
put "$repo" c.sh "cmd ${P} grep -F -- -x ${P} grep -Fq y"
put "$repo" d.sh "cmd ${P} grep -m 1 y"
put "$repo" e.sh "cmd ${P} grep --quiet y"
put "$repo" f.sh "cmd ${P} grep --max-count=1 y"
put "$repo" g.sh "first=\"\$(cmd ${P} head -n 1)\""
put "$repo" h.sh "cmd ${P}head"
put "$repo" i.sh "cmd ${P} egrep -q y"
put "$repo" j.sh "if cmd ${P}
  grep -q y; then :; fi"
put "$repo" k.sh "find . \\
  ${P} head -1"
put "$repo" actions/x/action.yml "runs:
  using: composite
  steps:
    - shell: bash
      run: |
        if find . ${P} grep -q .; then :; fi"
put "$repo" scripts/bin/tool "#!/usr/bin/env bash
cmd ${P} grep -q y"
run_case "every early-exit consumer in a pipeline is named" "$repo" 1 \
	a.sh:2 b.sh:1 c.sh:1 d.sh:1 e.sh:1 f.sh:1 g.sh:1 h.sh:1 i.sh:1 j.sh:2 \
	k.sh:2 actions/x/action.yml:6 scripts/bin/tool:2

repo=$(new_repo clean)
put "$repo" a.sh "if grep -q y <<<\"\$(cmd)\"; then :; fi
if a ${P}${P} grep -q y f; then :; fi
cmd ${P} grep -c y
cmd ${P} grep --line-number y
cmd ${P} grep -E 'a${P}b' f
cmd ${P} sed -n 1p
first=\"\$(grep -m 1 y f)\"
# cmd ${P} grep -q y, in a comment"
put "$repo" w.yml "steps:
  - run: ${P}
      grep -q y f
  - run: head -n 1 f"
put "$repo" notes.md "cmd ${P} grep -q y"
put "$repo" untracked-dir/keep.txt "x"
printf 'cmd %s grep -q y\n' "$P" >"$repo/untracked.sh"
run_case "a pipe with no early-exit consumer passes" "$repo" 0

repo=$(new_repo empty)
run_case "a repo with no shell or YAML file fails" "$repo" 1

out="$(bash "$CHECK" 2>&1)"
rc=$?
ok=0
[[ "$rc" -eq 2 && "$out" == usage:* ]] && ok=1
result "no argument prints usage and exits 2 (exit $rc)" "$ok" "$out"

# Why the check exists: under pipefail a consumer that exits on its first
# match kills the producer with SIGPIPE, so the pipeline fails although it
# matched. seq writes far more than a pipe holds, so it always loses. The
# pipe is built from ${P} so that this file does not trip the check.
(
	set -o pipefail
	eval "seq 1 200000 ${P} grep -q '^1\$'"
)
race_rc=$?
grep -q '^1$' <<<"$(seq 1 200000)"
fixed_rc=$?
ok=0
[[ "$race_rc" -ne 0 && "$fixed_rc" -eq 0 ]] && ok=1
result "pipefail fails a matching early-exit pipe; the here-string form does not (pipe $race_rc, here-string $fixed_rc)" \
	"$ok" ""

echo "early-exit-pipes: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
