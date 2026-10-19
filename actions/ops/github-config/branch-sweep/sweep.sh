#!/usr/bin/env bash
#
# Run `vrg-branch-sweep --apply` against $REPO and report every deleted
# branch in the job summary (issue #952).
#
# A deleted branch whose newest PR is MERGED means GitHub skipped its
# after-merge processing (the delete-on-merge setting never fired; see #951),
# so those are called out in a warning block and as `::warning::` annotations
# rather than listed alongside the routine closed-without-merging deletions.
#
# Fails closed: the step exits non-zero when the sweep does, and also when the
# sweep's output cannot be reconciled with its own summary line, so a change
# in vrg-branch-sweep's output format can never turn into an empty report.
set -euo pipefail

: "${REPO:?REPO must be set to OWNER/NAME}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY must be set}"
server="${GITHUB_SERVER_URL:-https://github.com}"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

status=0
vrg-branch-sweep --repo "$REPO" --apply 2>&1 | tee "$log" || status=$?

# Escape text for an HTML/markdown table cell: branch names may legally
# contain `|`, backticks and angle brackets.
html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/|/\&#124;/g' -e 's/`/\&#96;/g'
}

# Escape a workflow-command message (`%`, CR and LF are significant).
annotation_escape() {
  sed -e 's/%/%25/g'
}

# Per-branch lines are `<branch>  <#N|->  <STATE|->  <action> (<reason>)`.
# Ref names cannot contain whitespace, so whitespace splitting is exact.
# Each extractor prints `<branch>\t<pr-number>\t<rest-of-line>`.
extract() {
  local want_action="$1" want_state="$2"
  awk -v action="$want_action" -v state="$want_state" '
    $2 ~ /^#[0-9]+$/ && $4 == action && (state == "" || $3 == state) {
      rest = $0
      sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, "", rest)
      printf "%s\t%s\t%s\n", $1, substr($2, 2), rest
    }
    $2 == "-" && $4 == action && state == "" {
      rest = $0
      sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, "", rest)
      printf "%s\t\t%s\n", $1, rest
    }
  ' "$log"
}

merged="$(extract deleted MERGED)"
closed="$(extract deleted CLOSED)"
errors="$(extract error "")"

count() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}
n_merged="$(count "$merged")"
n_closed="$(count "$closed")"
n_errors="$(count "$errors")"
n_deleted=$((n_merged + n_closed))

# Reconcile against the sweep's own closing line:
#   <repo>: <N> branches, <D> deleted, <K> kept, <E> errors
summary_line="$(awk -v prefix="$REPO: " 'index($0, prefix) == 1 && / deleted, / { line = $0 } END { print line }' "$log")"
problem=""
if [ -n "$summary_line" ]; then
  reported_deleted="$(printf '%s\n' "$summary_line" | sed -n 's/.* branches, \([0-9][0-9]*\) deleted, .*/\1/p')"
  reported_errors="$(printf '%s\n' "$summary_line" | sed -n 's/.* kept, \([0-9][0-9]*\) errors.*/\1/p')"
  if [ "$reported_deleted" != "$n_deleted" ] || [ "$reported_errors" != "$n_errors" ]; then
    problem="vrg-branch-sweep reported ${reported_deleted:-?} deleted / ${reported_errors:-?} errors, but this step parsed ${n_deleted} deleted / ${n_errors} errors from its output; the output format may have changed."
  fi
elif [ "$status" -eq 0 ]; then
  problem="vrg-branch-sweep exited 0 but printed no summary line for $REPO; the output format may have changed."
fi

# table <tsv-rows>: one markdown row per `<branch>\t<pr>\t<detail>` line.
table() {
  local branch pr detail cell_pr
  printf '| Branch | PR | Detail |\n|---|---|---|\n'
  while IFS=$'\t' read -r branch pr detail; do
    if [ -n "$pr" ]; then
      cell_pr="[#${pr}](${server}/${REPO}/pull/${pr})"
    else
      cell_pr="-"
    fi
    printf '| <code>%s</code> | %s | %s |\n' \
      "$(printf '%s' "$branch" | html_escape)" "$cell_pr" \
      "$(printf '%s' "$detail" | html_escape)"
  done <<<"$1"
  printf '\n'
}

{
  printf '## Finished-branch sweep: `%s`\n\n' "$REPO"

  if [ "$n_merged" -gt 0 ]; then
    printf '> [!WARNING]\n'
    printf '> **%s branch(es) of merged PRs were still on origin.** ' "$n_merged"
    printf 'The delete-on-merge setting should have removed these when their PRs merged. '
    printf 'A leftover means GitHub skipped its after-merge processing, and the merge may '
    printf 'also have fired no push event. Check the workflows that should have run on these merges.\n\n'
    printf '### Deleted: merged PR, branch not auto-deleted\n\n'
    table "$merged"
  fi

  if [ "$n_closed" -gt 0 ]; then
    printf '### Deleted: PR closed without merging\n\n'
    table "$closed"
  fi

  if [ "$n_errors" -gt 0 ]; then
    printf '### Errors\n\n'
    table "$errors"
  fi

  if [ "$n_deleted" -eq 0 ] && [ "$n_errors" -eq 0 ] && [ -z "$problem" ] && [ "$status" -eq 0 ]; then
    printf 'No finished branches were left on origin.\n\n'
  fi

  if [ -n "$problem" ]; then
    printf '> [!CAUTION]\n> %s\n\n' "$(printf '%s' "$problem" | html_escape)"
  fi
  if [ "$status" -ne 0 ]; then
    printf '> [!CAUTION]\n> `vrg-branch-sweep` exited %s. See the full output below.\n\n' "$status"
  fi

  if [ -n "$summary_line" ]; then
    printf '%s\n\n' "$(printf '%s' "$summary_line" | html_escape)"
  fi
  printf '<details><summary>Full sweep output</summary>\n\n<pre>\n'
  html_escape <"$log"
  printf '</pre>\n\n</details>\n'
} >>"$GITHUB_STEP_SUMMARY"

if [ -n "$merged" ]; then
  while IFS=$'\t' read -r branch pr _; do
    msg="$(printf '%s' "$branch (PR #$pr) was merged but its branch was never auto-deleted; GitHub skipped its after-merge processing. Deleted by the sweep." | annotation_escape)"
    printf '::warning title=Merged-PR branch left on origin::%s\n' "$msg"
  done <<<"$merged"
fi

if [ -n "$problem" ]; then
  printf '::error title=Branch sweep report mismatch::%s\n' "$(printf '%s' "$problem" | annotation_escape)"
  [ "$status" -ne 0 ] || status=1
fi

exit "$status"
