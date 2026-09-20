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

# Two INDEPENDENT signals are required, not one marker: a severity/priority
# marker AND a `file:line` anchor. Only the mandated "None found." placeholder
# is exempt, because there the marker IS the content.
#
# This replaced four rounds of regex tuning, and the tuning is why. Each round
# found a longer prefix that still looked complete — a bare emoji, then the
# emoji plus the `[VERIFIED] High Priority:` label — because the template emits
# its parts in order, so EVERY truncation point leaves a valid-looking prefix.
# Detecting completeness from a prefix is not winnable by inspection; the fifth
# candidate regex still accepted both truncations.
#
# The anchor wins because of WHERE it sits. The template puts `file:line` at the
# end of the finding, after the description, so a response cut off in the
# scaffolding has not reached it. The two signals are orthogonal: narration can
# mention a filename, and a truncated finding can carry a severity marker, but
# neither produces both.
#
# Accepted cost, stated because it is a real fail-closed risk: a finding written
# with no `file:line` is rejected and takes the fallback + retry + fail-closed
# path. That shape is already off-contract — LADR-055 routes items with no
# single location to `residual_risks`/`testing_gaps`, not to Issues Found — and
# fail-closed is the correct direction for a gate whose worst outcome is an
# unreviewed chunk counted as clean.

# The mandated placeholder for an empty severity section. Exempt from the anchor
# requirement: a clean review has no finding, so it has no location to cite.
grep -qiF 'none found' "$_rhs_src" && exit 0

# Anchor: `some/file.ext:123`. Required for every finding-based acceptance.
if grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' "$_rhs_src"; then
  # Severity emoji, each as its own -e pattern: these are multi-byte and a
  # BRACKET expression over them decomposes into bytes and is locale-dependent.
  # (Alternation is safe; the bracket form is the trap.)
  grep -qE -e '🔴' -e '🟠' -e '🟡' -e '🔵' "$_rhs_src" && exit 0
  # "High Priority", "🟡 Medium Priority:", "low-priority" — any spelling. Safe
  # to accept on its own here because the anchor is already established; on its
  # own it matches ordinary prose ("check the high priority areas").
  grep -qiE '(critical|high|medium|low)[^[:alnum:]]{0,12}priority' "$_rhs_src" && exit 0
fi
exit 1
