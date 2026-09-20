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
# bracket expression over them is locale-dependent.
grep -qF -e '🔴' -e '🟠' -e '🟡' -e '🔵' "$_rhs_src" && exit 0
# "High Priority", "🟡 Medium Priority:", "low-priority" — any spelling.
grep -qiE '(critical|high|medium|low)[^[:alnum:]]{0,12}priority' "$_rhs_src" && exit 0
# The mandated placeholder for an empty severity section.
grep -qiF 'none found' "$_rhs_src" && exit 0
exit 1
