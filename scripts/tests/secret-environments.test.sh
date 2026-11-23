#!/usr/bin/env bash
# secret-environments.test.sh — tests for
# scripts/bin/check-secret-environments, the check that every workflow job
# reading a write-capable secret declares the environment that holds it
# (vergil-project/vergil-actions#1339, epic vergil-project/.github#1384).
#
# Each case builds a scratch git repo with chosen workflows, runs the check
# on it and asserts the exit status and the file and job its errors name.
# Run from anywhere; needs yq (mikefarah v4).
#
# Usage: bash scripts/tests/secret-environments.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../bin/check-secret-environments"
# The expression opener, kept out of this file's own text so that no
# fixture line reads as a GitHub Actions expression here.
# shellcheck disable=SC2016 # a literal GitHub Actions expression opener
O='${{'

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

# job <key> <environment line or ""> <step env line> — one job, as the text
# under `jobs:`, whose one step sets <step env line> in its env.
job() {
	local env_line=""
	[[ -n "$2" ]] && env_line="
    $2"
	printf '  %s:\n    runs-on: ubuntu-24.04%s\n    steps:\n      - run: echo hi\n        env:\n          %s\n' \
		"$1" "$env_line" "$3"
}

# workflow <repo> <name> <jobs text> — a staged workflow
# .github/workflows/<name> holding <jobs text> under `jobs:`.
workflow() {
	put "$1" ".github/workflows/$2" "name: test
on: workflow_call
jobs:
$3"
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

# run_case <name> <repo> <expected status> <expected file: job>...
# Each expected "file: job" must start an ERROR line, and no other
# "file: job" may.
run_case() {
	local name="$1" repo="$2" expect="$3" out rc loc ok=1 errors
	shift 3
	out="$(bash "$CHECK" "$repo" 2>&1)"
	rc=$?
	[[ "$rc" -eq "$expect" ]] || ok=0
	errors="$(grep -c '^ERROR: [^ ]*: [^ ]*: ' <<<"$out" || true)"
	[[ "$errors" -eq "$#" ]] || ok=0
	for loc in "$@"; do
		grep -qF "ERROR: $loc: " <<<"$out" || ok=0
	done
	result "$name (exit $rc, expected $expect)" "$ok" "$out"
}

app_id="APP: $O secrets.APP_CLIENT_ID }}"
app_key="KEY: $O secrets.APP_PRIVATE_KEY }}"

repo=$(new_repo app-keys)
workflow "$repo" a.yml "$(job none "" "$app_key")
$(job automation "environment: automation" "$app_key")
$(job other-env "environment: package-signing" "$app_id")"
run_case "an App key read outside the automation environment is named" "$repo" 1 \
	".github/workflows/a.yml: none" ".github/workflows/a.yml: other-env"

repo=$(new_repo map-form)
put "$repo" .github/workflows/b.yaml "name: test
on: workflow_call
jobs:
  report:
    runs-on: ubuntu-24.04
    environment:
      name: automation
    steps:
      - uses: ./actions/ops/report
        with:
          app-client-id: $O secrets.APP_CLIENT_ID }}
          app-private-key: $O secrets.APP_PRIVATE_KEY }}
  no-name:
    runs-on: ubuntu-24.04
    environment:
      url: https://example.invalid
    steps:
      - run: echo hi
        env:
          $app_key"
run_case "the environment's map form counts by its name, and a .yaml workflow is read" \
	"$repo" 1 ".github/workflows/b.yaml: no-name"

repo=$(new_repo publishing)
workflow "$repo" c.yml "$(job none "" "TOKEN: $O secrets.CARGO_REGISTRY_TOKEN }}")
$(job automation "environment: automation" "TOKEN: $O secrets.CARGO_REGISTRY_TOKEN }}")"
run_case "a publishing token read outside the automation environment is named" "$repo" 1 \
	".github/workflows/c.yml: none"

repo=$(new_repo signing)
workflow "$repo" d.yml "$(job none "" "K: $O secrets.PACKAGE_SIGNING_KEY }}")
$(job package "environment: package-signing" "K: $O secrets.PACKAGE_SIGNING_KEY }}")
$(job index "environment: index-signing" "K: $O secrets.PACKAGE_SIGNING_PASSPHRASE }}")
$(job automation "environment: automation" "K: $O secrets.PACKAGE_SIGNING_PASSPHRASE }}")"
run_case "a signing secret is read only in a signing environment" "$repo" 1 \
	".github/workflows/d.yml: none" ".github/workflows/d.yml: automation"

repo=$(new_repo read-only)
workflow "$repo" e.yml "$(job token "" "GH_TOKEN: $O secrets.GITHUB_TOKEN }}")
$(job conan "" "T: $O secrets.CONAN_AUDIT_PROVIDER_TOKEN_CONANCENTER }}")
$(job text "" "NOTE: pass secrets.APP_PRIVATE_KEY by name, or '$O \"x\" }}'")
$(job literal "" "X: $O contains(github.ref, 'secrets.APP_PRIVATE_KEY') }}")"
run_case "the run's own token, a read-only token and text that is no secret read pass" \
	"$repo" 0

repo=$(new_repo unclassified)
workflow "$repo" f.yml "$(job new-token "environment: automation" "T: $O secrets.NEW_TOKEN }}")
$(job dynamic "environment: automation" "T: $O toJSON(secrets) }}")
$(job indexed "environment: automation" "T: $O secrets['APP_PRIVATE_KEY'] }}")"
run_case "an unclassified secret and a dynamic read of the secrets context are named" \
	"$repo" 1 ".github/workflows/f.yml: new-token" ".github/workflows/f.yml: dynamic" \
	".github/workflows/f.yml: indexed"

repo=$(new_repo case)
workflow "$repo" g.yml "$(job lower "" "KEY: $O Secrets.app_private_key }}")
$(job spaced "" "KEY: $O format('{0}', secrets . APP_PRIVATE_KEY) }}")"
run_case "a secret named in another case or with spaces is still a read" "$repo" 1 \
	".github/workflows/g.yml: lower" ".github/workflows/g.yml: spaced"

repo=$(new_repo caller)
put "$repo" .github/workflows/h.yml "name: test
on: push
jobs:
  call:
    uses: org/repo/.github/workflows/x.yml@v1
    secrets:
      APP_CLIENT_ID: $O secrets.APP_CLIENT_ID }}
      APP_PRIVATE_KEY: $O secrets.APP_PRIVATE_KEY }}
  inherit:
    uses: org/repo/.github/workflows/x.yml@v1
    secrets: inherit"
run_case "a job that calls a reusable workflow runs no step and is not checked" "$repo" 0

repo=$(new_repo workflow-env)
put "$repo" .github/workflows/i.yml "name: test
on: push
env:
  $app_key
jobs:
$(job automation "environment: automation" "X: y")"
run_case "a secret read in the workflow-level env is named" "$repo" 1 \
	".github/workflows/i.yml: (workflow)"

repo=$(new_repo expression-env)
workflow "$repo" j.yml "$(job dynamic "environment: $O inputs.environment }}" "$app_key")"
run_case "an environment named by an expression does not count" "$repo" 1 \
	".github/workflows/j.yml: dynamic"

repo=$(new_repo malformed)
put "$repo" .github/workflows/k.yml "name: test
jobs: [unclosed"
run_case "a workflow that does not parse fails the check" "$repo" 1 \
	".github/workflows/k.yml: (workflow)"

repo=$(new_repo untracked)
workflow "$repo" ok.yml "$(job automation "environment: automation" "$app_key")"
mkdir -p "$repo/.github/workflows"
printf 'jobs:\n  x:\n    steps:\n      - env:\n          %s\n' "$app_key" >"$repo/.github/workflows/untracked.yml"
run_case "an untracked workflow is not read" "$repo" 0

repo=$(new_repo empty)
run_case "a repo with no workflow fails" "$repo" 1

out="$(bash "$CHECK" 2>&1)"
rc=$?
ok=0
[[ "$rc" -eq 2 && "$out" == usage:* ]] && ok=1
result "no argument prints usage and exits 2 (exit $rc)" "$ok" "$out"

echo "secret-environments: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
