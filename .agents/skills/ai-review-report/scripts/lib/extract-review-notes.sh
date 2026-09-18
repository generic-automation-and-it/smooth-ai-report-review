#!/bin/bash
# extract-review-notes.sh — pull the PR author's review guidance out of a PR body.
#
# Usage:  AI_REVIEW_NOTES="$(printf '%s' "$PR_DESCRIPTION" | bash lib/extract-review-notes.sh)"
#
# Pure stdin -> stdout, no filesystem, always exit 0. Empty output means neither
# section was present, which is the caller's cue to omit the prompt block.
#
# Why this exists (LADR-083). Both `review-in-chunks.sh` and
# `aggregate-reviews.sh` carried the same one-liner:
#
#   awk '/^## AI Review Notes/{flag=1; next} /^## /{flag=0} flag'
#
# which captures ONLY the `## AI Review Notes` section. The PR description's
# `## Skip Areas / Known Issues` bullets are a SIBLING `##` section, so they were
# never captured and never reached a prompt — while `review-in-chunks.sh` told the
# model:
#
#   - Any items listed under **"Skip Areas"** MUST be treated as out-of-scope
#     for Critical, High and Medium classifications.
#
# a rule pointing at a section that was not in the prompt. Verified against
# generic-automation-and-it/smooth-ai-product-context-memory PR #72: the extracted
# notes contained zero occurrences of that PR's skip bullet.
#
# The consequence is the one LADR-055's channel exists to prevent: the bullets are
# what `ai-review execute` is REQUIRED to write for every skipped finding (see the
# repo's Non-Negotiables), and they are what the next round's gate is documented to
# read in order to tell an intentional skip from an unread finding. With the narrow
# awk the only thing suppressing a re-raise was the `### AI Review Response` table,
# captured incidentally because `ai-review` appends it at `###` level INSIDE the
# notes section. So the two channels were exactly inverted relative to the docs:
# the human-facing table was load-bearing and the load-bearing bullets were inert.
#
# Two properties an editor must preserve. The Skip Areas body is emitted WITH a
# heading that still contains the literal string `Skip Areas`, demoted to `###` so
# it nests under the prompt's own `## 📝 AI REVIEW NOTES` block — drop the heading
# and the prompt rule loses its referent again. And it is emitted LAST, adjacent to
# that rule, because a section named by a rule 40 lines earlier is easy for a model
# to lose track of.

set -uo pipefail

NOTES_HEADING_RE='^## AI Review Notes'
SKIP_HEADING_RE='^## Skip Areas'

_body="$(cat)"

# Section body, heading line excluded, terminated by the next `## ` heading (or
# EOF). `next` on the match is what drops the heading; the caller re-adds one for
# Skip Areas below.
_section() {
  awk -v re="$1" '$0 ~ re {flag=1; next} /^## /{flag=0} flag'
}

# Comment stripping and blank-line squeezing are carried over verbatim from the
# call sites this lib replaced, so a body with no Skip Areas section produces
# byte-identical output to the pre-LADR-083 gate.
_clean() {
  sed '/^<!--/,/-->$/d' | sed '/^$/d'
}

_notes=""
if printf '%s\n' "$_body" | grep -q "$NOTES_HEADING_RE"; then
  _notes="$(printf '%s\n' "$_body" | _section "$NOTES_HEADING_RE" | _clean)"
fi

_skips=""
if printf '%s\n' "$_body" | grep -q "$SKIP_HEADING_RE"; then
  _skips="$(printf '%s\n' "$_body" | _section "$SKIP_HEADING_RE" | _clean)"
fi

if [ -n "$_notes" ]; then
  printf '%s\n' "$_notes"
fi
if [ -n "$_skips" ]; then
  [ -n "$_notes" ] && printf '\n'
  printf '### Skip Areas / Known Issues\n%s\n' "$_skips"
fi

exit 0
