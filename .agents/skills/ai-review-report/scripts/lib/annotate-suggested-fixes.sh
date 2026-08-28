#!/bin/bash
# annotate-suggested-fixes.sh — reconcile `## 📝 Suggested Fixes` with the
# post-validation finding set (issue #125).
#
# Usage:
#   annotate-suggested-fixes.sh <merged_json> <summary_md>
#
# Issue #125 asks that severity sections, coverage counts, suggested fixes and
# the verdict all derive from ONE post-validation finding set. Four of those five
# now do. `## 📝 Suggested Fixes` cannot: it is the orchestrator's own prose,
# written from the chunk markdown, and there is no deterministic mapping from a
# prose fix paragraph back to a merged finding — rewriting it would mean asking a
# model to redo the section, which is a second model call and a second thing that
# can truncate.
#
# So instead of pretending the section is synced, this makes the gap legible: when
# the merge dropped, suppressed or demoted anything, a note under the heading says
# so, with counts, and points at the Coverage block and the verbatim per-chunk
# reviews. A reader who sees a fix with no numbered finding gets an explanation
# instead of concluding the report contradicts itself.
#
# No-ops (exit 0, file untouched) when: inputs are missing, jq is absent, the
# merged document is not `complete`, there is no Suggested Fixes heading, nothing
# was dropped/suppressed/demoted, or a note is already present. Best-effort by
# construction, exactly like number-holistic-items.sh — a missing note is
# cosmetic, a mangled report is not.
#
# LADR-067: nothing emitted here may contain `#` followed by digits.
set -uo pipefail

merged="${1:-}"
summary="${2:-}"

[ -n "$merged" ] && [ -s "$merged" ] || exit 0
[ -n "$summary" ] && [ -f "$summary" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e '.status == "complete"' "$merged" >/dev/null 2>&1 || exit 0
grep -q '^## 📝 Suggested Fixes' "$summary" || exit 0
grep -q 'Some suggested fixes may have no numbered finding' "$summary" && exit 0

malformed=$(jq -r '(.malformed_findings // 0) | tostring' "$merged" 2>/dev/null || echo 0)
suppressed=$(jq -r '((.suppressed_findings // []) | length) | tostring' "$merged" 2>/dev/null || echo 0)
demoted=$(jq -r '(.demoted_no_quote // 0) | tostring' "$merged" 2>/dev/null || echo 0)
case "$malformed" in ''|*[!0-9]*) malformed=0 ;; esac
case "$suppressed" in ''|*[!0-9]*) suppressed=0 ;; esac
case "$demoted" in ''|*[!0-9]*) demoted=0 ;; esac

if [ "$malformed" -eq 0 ] && [ "$suppressed" -eq 0 ] && [ "$demoted" -eq 0 ]; then
  exit 0
fi

reasons=""
add_reason() { # add_reason <text>
  if [ -z "$reasons" ]; then reasons="$1"; else reasons="$reasons; $1"; fi
}
[ "$malformed" -gt 0 ]  && add_reason "${malformed} finding(s) were dropped as malformed"
[ "$suppressed" -gt 0 ] && add_reason "${suppressed} were suppressed below the actionable confidence anchor"
[ "$demoted" -gt 0 ]    && add_reason "${demoted} were demoted for not quoting the motivating line"

note="> ℹ️ **Some suggested fixes may have no numbered finding.** The Issues Summary above is the post-validation set: ${reasons}. A fix suggested below can therefore describe an item that carries no number. The Coverage block above gives the reason for each, and the per-chunk reviews in the detailed section carry every one of them verbatim."

tmp="$(mktemp)" || exit 0
trap 'rm -f "$tmp"' EXIT

awk -v note="$note" '
  { print }
  done_it == 0 && /^## 📝 Suggested Fixes/ {
    print ""
    print note
    print ""
    done_it = 1
  }
' "$summary" > "$tmp" 2>/dev/null || exit 0

# A rewrite that lost lines is a bug, not an improvement — leave the file alone.
# `wc -l` pads its output with spaces on BSD/macOS — strip it, or the numeric
# guard below rejects every value and the note is never applied.
before=$(wc -l < "$summary" 2>/dev/null | tr -d '[:space:]' || echo 0)
after=$(wc -l < "$tmp" 2>/dev/null | tr -d '[:space:]' || echo 0)
before="${before:-0}"; after="${after:-0}"
case "$before$after" in *[!0-9]*) exit 0 ;; esac
[ "$after" -ge "$before" ] || exit 0
[ -s "$tmp" ] || exit 0

mv "$tmp" "$summary" || exit 0
trap - EXIT
echo "Annotated Suggested Fixes: malformed=${malformed} suppressed=${suppressed} demoted=${demoted}" >&2
exit 0
