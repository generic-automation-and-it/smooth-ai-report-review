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

# Severity emoji: -F with one -e each, because these are multi-byte and a
# bracket expression over them is locale-dependent. Strong evidence on its own
# — exploration narration does not emit 🔴/🟠/🟡/🔵.
grep -qF -e '🔴' -e '🟠' -e '🟡' -e '🔵' "$_rhs_src" && exit 0
# The mandated placeholder for an empty severity section. Also strong: it is
# the literal string the template asks for when there is nothing to report.
grep -qiF 'none found' "$_rhs_src" && exit 0
# Priority wording — "High Priority", "🟡 Medium Priority:", "low-priority" —
# is the WEAK clause, because it matches ordinary prose. "Let me check the high
# priority areas before reviewing." is 55 bytes of narration that satisfies it
# while containing no review at all, and the chunk would then be aggregated as
# clean with zero findings. It was tolerable while the 200-byte floor ran in
# front of this predicate; with the floor gone (LADR-087) it is not.
#
# So this clause alone is not enough: the mandated section marker has to be
# present too. That keeps it useful for a model that writes real findings in
# prose rather than emoji, while narration — which has no `Issues Found`
# section — is rejected and takes the fallback + fail-closed path.
#
# Deliberately NOT promoting `Issues Found` to a standalone clause: the marker
# is emitted before any content, so a response truncated right after it would
# pass while containing nothing (the finding-2 shape from the previous round).
if grep -qiE '(critical|high|medium|low)[^[:alnum:]]{0,12}priority' "$_rhs_src" \
   && grep -qiF 'issues found' "$_rhs_src"; then
  exit 0
fi
exit 1
