#!/usr/bin/env bash
#
# Test when ci-security's CodeQL job runs and when its evidence gate accepts
# a skipped CodeQL result (Review focus 2 of epic vergil-project/.github#1476).
# The codeql job runs whenever run-security and run-codeql are true, and the
# evidence gate requires it to have succeeded then. The gate accepts a
# skipped codeql job only when run-codeql is false.
#
# Framework-free and developer-runnable: `bash security-gate.test.sh`. CI
# runs it from .github/workflows/smoke-setup-vergil.yml. It needs `yq`
# (mikefarah v4) and `python3`, both preinstalled on GitHub's ubuntu runners.
#
# The test evaluates the real `if:` expressions of the codeql and evidence
# jobs. The evaluator below knows only the expression forms those two
# conditions use (`always()`, `inputs.<name>`, `needs.<job>.result`, quoted
# strings, `true`/`false`, `==`, `!=`, `!`, `&&`, `||` and parentheses). Any
# other form, or a context name the case does not set, is an error, so an
# input the condition still reads beyond run-security and run-codeql fails
# the case. The same checks then run against two broken copies of the
# workflow (the old gate that accepted a skipped codeql job unconditionally,
# and a codeql job gated on a further input), which must fail, so the test
# is shown to catch the drift it guards.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../../.." && pwd)"
workflow="${repo_root}/.github/workflows/ci-security.yml"

for tool in yq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'security-gate.test.sh needs %s on PATH\n' "$tool" >&2
    exit 1
  fi
done
if [ ! -f "$workflow" ]; then
  printf 'security-gate.test.sh: missing %s\n' "$workflow" >&2
  exit 1
fi

pass=0
fail=0

fail_case() {
  printf 'not ok - %s: %s\n' "$1" "$2" >&2
  fail=$((fail + 1))
}

pass_case() {
  printf 'ok - %s\n' "$1"
  pass=$((pass + 1))
}

# evaluate <expression> <name=value>... — prints true or false, the
# expression's truth with each context name set to its value (true and false
# are booleans, anything else a string). Fails, with the reason on stderr,
# on a form the evaluator does not know or a context name not given.
evaluate() {
  python3 - "$@" <<'PY'
import re
import sys

expr = sys.argv[1].strip()
if expr.startswith("${{") and expr.endswith("}}"):
    expr = expr[3:-2]
ctx = {}
for arg in sys.argv[2:]:
    name, _, value = arg.partition("=")
    ctx[name] = {"true": True, "false": False}.get(value, value)

token_re = re.compile(
    r"\s*(?:(?P<op>&&|\|\||==|!=|!|\(|\))|'(?P<str>[^']*)'"
    r"|(?P<call>always\(\))|(?P<name>[A-Za-z_][A-Za-z0-9_.-]*))"
)
tokens = []
pos = 0
while pos < len(expr):
    if expr[pos:].strip() == "":
        break
    m = token_re.match(expr, pos)
    if not m:
        sys.exit(f"unknown expression form at: {expr[pos:]!r}")
    pos = m.end()
    if m.group("op"):
        tokens.append(("op", m.group("op")))
    elif m.group("str") is not None:
        tokens.append(("val", m.group("str")))
    elif m.group("call"):
        tokens.append(("val", True))
    else:
        name = m.group("name")
        if name in ("true", "false"):
            tokens.append(("val", name == "true"))
        elif name in ctx:
            tokens.append(("val", ctx[name]))
        else:
            sys.exit(f"context name {name!r} is not set by the case")
tokens.append(("end", None))
i = 0


def peek():
    return tokens[i]


def take(kind, value=None):
    global i
    tok = tokens[i]
    if tok[0] != kind or (value is not None and tok[1] != value):
        sys.exit(f"unexpected token {tok!r}")
    i += 1
    return tok


def parse_or():
    left = parse_and()
    while peek() == ("op", "||"):
        take("op")
        right = parse_and()
        left = left or right
    return left


def parse_and():
    left = parse_eq()
    while peek() == ("op", "&&"):
        take("op")
        right = parse_eq()
        left = left and right
    return left


def parse_eq():
    left = parse_unary()
    if peek() in (("op", "=="), ("op", "!=")):
        op = take("op")[1]
        right = parse_unary()
        return (left == right) if op == "==" else (left != right)
    return left


def parse_unary():
    if peek() == ("op", "!"):
        take("op")
        return not parse_unary()
    return parse_primary()


def parse_primary():
    if peek() == ("op", "("):
        take("op")
        value = parse_or()
        take("op", ")")
        return value
    return take("val")[1]


result = parse_or()
take("end")
print("true" if result else "false")
PY
}

# expect <label> <want> <expression> <name=value>... — records whether the
# expression evaluates to <want>; an evaluation error is a failure.
# Returns non-zero on a failure so check_workflow can stop at the first one.
expect() {
  local label="$1" want="$2" expr="$3" got
  shift 3
  if ! got="$(evaluate "$expr" "$@" 2>&1)"; then
    echo "${label}: ${got}"
    return 1
  fi
  if [ "$got" != "$want" ]; then
    echo "${label}: evaluated ${got}, want ${want}"
    return 1
  fi
}

# check_workflow <workflow> — prints the first problem found and fails, or
# succeeds silently.
check_workflow() {
  local wf="$1" codeql_if gate_if
  codeql_if="$(yq -r '.jobs.codeql.if' "$wf")"
  gate_if="$(yq -r '.jobs.evidence.if' "$wf")"

  # The codeql job runs whenever run-security and run-codeql are true, and
  # only then; it reads no other input.
  expect "codeql job, run-security and run-codeql true" true "$codeql_if" \
    inputs.run-security=true inputs.run-codeql=true || return 1
  expect "codeql job, run-codeql false" false "$codeql_if" \
    inputs.run-security=true inputs.run-codeql=false || return 1
  expect "codeql job, run-security false" false "$codeql_if" \
    inputs.run-security=false inputs.run-codeql=true || return 1

  local ok=(needs.trivy.result=success needs.semgrep.result=success)
  local on=(inputs.run-security=true inputs.run-codeql=true)
  local off=(inputs.run-security=true inputs.run-codeql=false)

  # With run-codeql true, the gate requires codeql to have succeeded.
  expect "gate, run-codeql true, codeql success" true "$gate_if" \
    "${on[@]}" "${ok[@]}" needs.codeql.result=success || return 1
  local r
  for r in skipped failure cancelled; do
    expect "gate, run-codeql true, codeql ${r}" false "$gate_if" \
      "${on[@]}" "${ok[@]}" "needs.codeql.result=${r}" || return 1
  done

  # With run-codeql false, the gate accepts the skipped codeql job.
  expect "gate, run-codeql false, codeql skipped" true "$gate_if" \
    "${off[@]}" "${ok[@]}" needs.codeql.result=skipped || return 1

  # A failed scanner fails the gate whatever codeql did.
  expect "gate, trivy failed" false "$gate_if" "${on[@]}" \
    needs.trivy.result=failure needs.semgrep.result=success \
    needs.codeql.result=success || return 1
  expect "gate, semgrep failed" false "$gate_if" "${off[@]}" \
    needs.trivy.result=success needs.semgrep.result=failure \
    needs.codeql.result=skipped || return 1
}

# The real workflow must pass.
if msg="$(check_workflow "$workflow")"; then
  pass_case "ci-security-codeql-gate"
else
  fail_case "ci-security-codeql-gate" "$msg"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect_broken <name> <workflow-copy> — the copy must fail the checks.
expect_broken() {
  if msg="$(check_workflow "$2")"; then
    fail_case "$1" "a broken workflow passed the checks"
  else
    pass_case "$1 (${msg})"
  fi
}

# The old gate, which accepted a skipped codeql job even with run-codeql on.
old_gate="\${{ always() && needs.trivy.result == 'success' &&"
old_gate+=" needs.semgrep.result == 'success' &&"
old_gate+=" (needs.codeql.result == 'success' ||"
old_gate+=" needs.codeql.result == 'skipped') }}"
EXPR="$old_gate" yq '.jobs.evidence.if = strenv(EXPR)' "$workflow" \
  >"${tmp}/skip-always.yml"
expect_broken "detects-a-gate-accepting-skipped-codeql" "${tmp}/skip-always.yml"

# A codeql job gated on a further input, as it once was on code-scanning access.
further="\${{ inputs.run-security && inputs.run-codeql &&"
further+=" inputs.code-scanning }}"
EXPR="$further" yq '.jobs.codeql.if = strenv(EXPR)' "$workflow" \
  >"${tmp}/further-input.yml"
expect_broken "detects-codeql-gated-on-a-further-input" "${tmp}/further-input.yml"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
