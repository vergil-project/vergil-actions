# The All-Hard-Gates Principle

**Every check that matters is a hard, asserting gate. There are no
report-only or warning gates.**

This is a foundational principle of the vergil CI model, not a style
preference. It governs how every gate in the [CI gate
requirements](required-checks.md) is designed: a check either fails the
build when it fires, or it does not exist.

## The principle

A gate has exactly two possible dispositions:

- **Pass** — the condition it asserts holds; the build proceeds.
- **Fail** — the condition does not hold; the build stops, loudly and
  terminally, until the underlying problem is fixed.

There is deliberately no third disposition. No check emits a warning that
the build carries forward. No check writes an advisory that a human is
trusted to notice later. If a condition is worth checking at all, it is
worth failing on — so it is a hard gate.

## Why warnings are worthless here

A warning only has value if a human reliably acts on it. That assumption
does not survive contact with how code actually gets merged.

At modern code-generation rates, the volume of change moving through
review is far larger than the human attention available to scrutinize it.
Reviewers optimize for the single question that governs the merge button:
**"Can I merge?"** A warning does not block the merge, so it does not
answer that question, so it does not get read. Once a change is merged,
nobody revisits it to chase down a warning that was already, by
definition, deemed non-blocking.

!!! quote "The operative failure mode"
    An unheeded warning is indistinguishable from no warning at all. A
    signal that no one is required to act on, and that no mechanism forces
    anyone to act on, is not a safeguard — it is noise that provides the
    *appearance* of a safeguard while delivering none of its protection.

So a report-only gate is worse than useless: it costs the same to build
and run as a real gate, it clutters output, and it lulls the team into
believing a class of problem is "covered" when in practice nothing stops
that problem from shipping. The honest options are to **assert it and fail
on it**, or to not check it at all. There is no coherent middle.

## Deprecation warnings are errors

Deprecation warnings are the clearest case, because they are not really
warnings — they are **early signal of a future outage**. A deprecated API,
flag, or action is announcing a date on which it will stop working. Left
as a warning, that signal decays into background noise and is rediscovered
only when the deprecation becomes a removal and the pipeline breaks in
production.

Treating deprecation warnings as errors converts a future, unscheduled
outage into a present, scheduled unit of work — surfaced while the context
is fresh and the fix is cheap, instead of during the incident it would
otherwise become. See [`/vergil:deprecation-triage`] for the workflow that
turns each such error into a tracked decision.

[`/vergil:deprecation-triage`]: https://github.com/vergil-project/vergil-tooling

## No five-page exception list

The failure mode this principle guards against is the sprawling
warning-exception list: a document that accumulates "known" warnings, each
with a rationale for why *this one* is tolerated, until the list is five
pages long and no one can tell which entries still matter. Such a list is a
graveyard of decisions no one is accountable for, and every entry is a
place where a real regression can hide in plain sight.

The rule that prevents it is simple:

> **If it matters, assert it and fail on it. If it does not matter enough to
> fail on, do not check it.**

This keeps the gate set small, meaningful, and trustworthy: every gate that
exists is one the build genuinely depends on, and a green build is a
categorical statement, not a statement with a footnote.

## Why this makes public evidence bundles safe

This principle is load-bearing for the CI-evidence archival work (epic
[vergil-project/.github#140]). That epic publishes a complete, attested
**evidence bundle** as a public asset on every release, capturing the
output of every gate.

Bundling *everything* onto a public artifact is safe **precisely because
every gate is a hard gate.** Evidence generation runs only after all gates
are green, and because there are no report-only or warning gates, a bundle
by construction reflects a *passing* run with no unremediated findings to
expose. The publish-safety property (epic #140 spec §9.1) depends directly
on this model:

!!! warning "The dependency is explicit"
    Introducing any soft or report-only gate in the future would break this
    boundary. A passing release could then carry non-fatal findings into a
    public bundle, and the publish-safety guarantee would have to be
    revisited. The all-hard-gates principle is therefore not just a code-
    quality stance — it is a precondition of safely publishing CI evidence.

[vergil-project/.github#140]: https://github.com/vergil-project/.github/issues/140

## See also

- [Required Checks](required-checks.md) — the concrete gate set this
  principle governs.
- [Repository Rulesets](repository-rulesets.md) — how gates are enforced as
  required status checks that block merge.
- [Security Scanning](security-scanning.md) — the CodeQL, Semgrep, and
  Trivy gates, each a hard gate.
