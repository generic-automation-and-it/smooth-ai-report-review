#!/bin/bash
# review-has-shape.sh — does this text contain a COMPLETED chunk review?
#
# Usage:  review-has-shape.sh <file>     # or pipe the text on stdin
# Exit 0 = yes, 1 = no. Prints nothing.
#
# One predicate, two callers, on purpose. `review-in-chunks.sh` uses it to
# decide whether a chunk was reviewed at all (LADR-031 fail-closed), and
# `lib/opencode-with-fallback.sh` uses it — when a caller opts in via
# OPENCODE_OUTPUT_SHAPE_CHECK — to decide whether a short answer is a real
# review or a silent failure. They MUST agree: when the transport accepted
# something the chunk gate then rejected, the transport had already spent the
# LADR-002 fallback on it, so the secondary model never ran and the chunk
# fail-closed with rescue capacity unused. A single literal marker could not
# express this (the "None found." placeholder and a severity line are
# alternatives, and one of them is a regex), which is how the two drifted apart
# in the first place.
#
# The three clauses below are the completion signals the chunk prompt's output
# template guarantees: it mandates `**Issues Found:**` followed by either
# findings (severity emoji, or "… Priority" wording) or the literal
# "None found." placeholder. Deliberately NO heading-only clause — the heading
# is the template's FIRST line, so a response truncated right after it would
# match while containing no review, and an unreviewed chunk counted as clean is
# the one outcome this gate exists to prevent (LADR-087).
#
# Bash 3.2 safe: local-review.sh reaches both callers without a Bash >= 4 guard.
set -uo pipefail

_rhs_src="${1:-}"
if [ -n "$_rhs_src" ]; then
  [ -f "$_rhs_src" ] || exit 1
else
  _rhs_src="$(mktemp)"
  trap 'rm -f "$_rhs_src"' EXIT
  cat > "$_rhs_src"
fi

# Completeness is decided by the LAST per-file section, then by two
# INDEPENDENT signals within it.
#
# Scope first, because a chunk is almost always MULTI-FILE and an earlier
# complete section says nothing about whether the model finished. A body that
# reports "None found." for file A and is then cut off part-way through file B
# is not a completed review of that chunk — but every earlier version of this
# predicate searched the whole body, so file A's result vouched for file B.
# Narrowing to the final section is what makes the signals mean "the model
# reached the end" rather than "the model started".
#
# Then two signals, because one marker is never enough. Four rounds of regex
# tuning each closed one truncation shape and the next round found a longer
# prefix, since the template emits its parts in order and every cut leaves a
# valid-looking prefix. The `file:line` anchor works because of WHERE it sits —
# at the end of a finding, after the description — so scaffolding cut short
# never reaches it, and the signals are orthogonal: narration can name a file,
# a truncated finding can carry a marker, neither produces both.
#
# Accepted cost, stated because it is a real fail-closed risk: a finding
# written with no `file:line` is rejected and takes the retry + fail-closed
# path. That shape is already off-contract — LADR-055 routes location-less
# items to `residual_risks`/`testing_gaps` — and fail-closed is the correct
# direction for a gate whose worst outcome is an unreviewed chunk counted clean.

# Narrow to the last per-file section. No heading at all means the whole body
# is the section, which keeps LADR-077's deliberate acceptance of findings
# written without the template scaffolding.
_rhs_tail="$(mktemp)"
trap 'rm -f "$_rhs_tail" 2>/dev/null' EXIT
awk '/^#+[[:space:]].*File:/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' \
  "$_rhs_src" > "$_rhs_tail" 2>/dev/null || cp "$_rhs_src" "$_rhs_tail"
[ -s "$_rhs_tail" ] || cp "$_rhs_src" "$_rhs_tail" 2>/dev/null

# The mandated placeholder for an empty severity section. Exempt from the
# anchor requirement: a clean result has no finding, so it has no location to
# cite. Scoped to the last section, so it can only vouch for itself.
grep -qiF 'none found' "$_rhs_tail" && exit 0

# Anchor: `some/file.ext:123`. Required for every finding-based acceptance.
if grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' "$_rhs_tail"; then
  # Severity emoji, each as its own -e pattern: these are multi-byte and a
  # BRACKET expression over them decomposes into bytes and is locale-dependent.
  # (Alternation is safe; the bracket form is the trap.)
  grep -qE -e '🔴' -e '🟠' -e '🟡' -e '🔵' "$_rhs_tail" && exit 0
  # Priority wording additionally requires the mandated section marker. On its
  # own it matches ordinary prose, and prose can carry a location too — "check
  # the high priority areas in run-review.sh:1196" satisfied both signals while
  # containing no review. Narration does not emit `Issues Found`.
  if grep -qiE '(critical|high|medium|low)[^[:alnum:]]{0,12}priority' "$_rhs_tail" \
     && grep -qiF 'issues found' "$_rhs_tail"; then
    exit 0
  fi
fi
exit 1
