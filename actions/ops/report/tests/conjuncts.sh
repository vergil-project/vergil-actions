# shellcheck shell=bash
#
# Shared by release-push-skip.test.sh and docs-refresh-reports-once.test.sh
# (issue #1362): source it, never run it.
#
# conjuncts <expression> — print the top-level `&&` operands of a GitHub
# Actions expression, one per line, whitespace collapsed. Parentheses and
# single-quoted strings nest, so an operand inside an `||` or a parenthesis
# is never printed on its own: only a top-level operand turns a job off by
# itself.
conjuncts() {
  local expr i c depth=0 quoted=0 cur=""
  expr="$(tr -s '[:space:]' ' ' <<<"$1" | sed 's/^ //; s/ $//')"
  for ((i = 0; i < ${#expr}; i++)); do
    c="${expr:i:1}"
    if [ "$quoted" -eq 1 ]; then
      [ "$c" = "'" ] && quoted=0
    elif [ "$c" = "'" ]; then
      quoted=1
    elif [ "$c" = "(" ]; then
      depth=$((depth + 1))
    elif [ "$c" = ")" ]; then
      depth=$((depth - 1))
    elif [ "$depth" -eq 0 ] && [ "${expr:i:2}" = "&&" ]; then
      printf '%s\n' "$(sed 's/^ //; s/ $//' <<<"$cur")"
      cur=""
      i=$((i + 1))
      continue
    fi
    cur+="$c"
  done
  printf '%s\n' "$(sed 's/^ //; s/ $//' <<<"$cur")"
}
