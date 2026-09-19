#!/bin/bash
# sync-recommendation-from-findings.sh — rewrite Recommendation counts + decision
# from the post-validation merged findings document (issue #125 / LADR-055).
#
# Usage:
#   sync-recommendation-from-findings.sh <merged_json> <summary_md> [holistic_md]
#
# Environment:
#   SYNC_ORIGINAL_ACTION  the orchestrator's own MACHINE_READABLE_ACTION
#                         (approve | comment | request_changes). When the merged
#                         set carries no blocker, a `comment` verdict is
#                         PRESERVED as `comment` rather than upgraded to a real
#                         GitHub APPROVE — approving is a state change that can
#                         satisfy branch protection, and "no Critical/High" is
#                         not the same claim as "I approve this PR".
#
# Edits <summary_md> in place. Prints the machine-readable decision to stdout
# (request_changes | approve | comment). Exit 0 on success, 1 when inputs are
# unusable (caller keeps the orchestrator's recommendation).
#
# Why this exists
# ---------------
# aggregate-reviews.sh replaces `## 🔍 Issues Summary` with a render of the
# merged findings, but left `## 🎯 Recommendation` as the orchestrator wrote it.
# The orchestrator counted the Issues Summary *it* wrote (from chunk markdown),
# so a finding the merge later dropped as malformed still gated REQUEST_CHANGES
# while every severity section said "None found". Severity lists, count lines,
# rationale, and MACHINE_READABLE_ACTION must share one post-validation set.
#
# WHEN THE CALLER MAY INVOKE THIS
# -------------------------------
# This script can SOFTEN a verdict, so the caller owns preconditions that are
# not checkable from here (see aggregate-reviews.sh):
#   1. FULL sidecar coverage. On partial coverage the merged set is missing a
#      reviewed chunk's findings entirely, so "no Critical/High in the merged
#      set" is not evidence of "no Critical/High in the PR" — a truncated
#      sidecar (the most common structured-findings failure) would soften the
#      verdict on findings nobody dropped on purpose.
#   2. No chunk remains failed when the orchestrator summary also failed. A
#      summary-only failure does not invalidate complete chunk reviews or their
#      fully-ingested structured findings; in that case this script replaces the
#      temporary REQUEST_CHANGES fallback with the deterministic findings verdict.
#      If chunk coverage also failed, the caller keeps its fail-closed action.
# On incomplete coverage the caller skips this script and keeps its own one-
# directional escalate-only path.
#
# Decision rule (same tree the orchestrator prompt states):
#   critical > 0 OR high > 0  → request_changes
#   else                      → approve, or comment when the orchestrator said so
# Holistic Critical/High items (no per-chunk sidecar entry) still block: when
# the merged set has no critical/high, a non-empty Critical/High item under
# Cross-Chunk Issues Found in [holistic_md] forces request_changes. Failed
# chunks are handled by the caller (LADR-031/036), not here.
#
# Count lines rewritten (when present):
#   - Count of 🔴 Critical Issues: N
#   - Count of 🟠 High Priority Issues: N
#   - Count of 🟡 Medium Priority Issues: N
#   - Count of 🔵 Low Priority Issues: N
#   - Count of 🗂️ Pre-existing issues: N
# The rewrite replaces ONLY the number, so `**bold labels:** 3`, a trailing
# note ("— these do NOT block the PR"), and an unfilled `[number - …]`
# placeholder all survive intact. A label-shape mismatch that silently left a
# stale count behind is the same body↔state contradiction this script exists to
# remove.
# Soft buckets (residual_risks / testing_gaps) are NOT medium findings for the
# verdict — they render into the Medium section untagged and stay out of these
# counts, matching score-review.sh.
set -euo pipefail

merged="${1:-}"
summary="${2:-}"
holistic="${3:-}"

if [ -z "$merged" ] || [ ! -s "$merged" ]; then
  exit 1
fi
if [ -z "$summary" ] || [ ! -f "$summary" ]; then
  exit 1
fi
command -v jq >/dev/null 2>&1 || exit 1
jq -e '.status == "complete"' "$merged" >/dev/null 2>&1 || exit 1

counts="$(jq -c '
  {
    critical: [(.findings // [])[] | select(.severity == "critical")] | length,
    high:     [(.findings // [])[] | select(.severity == "high")] | length,
    medium:   [(.findings // [])[] | select(.severity == "medium")] | length,
    low:      [(.findings // [])[] | select(.severity == "low")] | length,
    pre_existing: (.pre_existing_findings // []) | length
  }
' "$merged" 2>/dev/null)" || exit 1

crit=$(printf '%s' "$counts" | jq -r .critical)
high=$(printf '%s' "$counts" | jq -r .high)
med=$(printf '%s' "$counts" | jq -r .medium)
low=$(printf '%s' "$counts" | jq -r .low)
pre=$(printf '%s' "$counts" | jq -r .pre_existing)

# Holistic Critical/High still gate even when the merged set is empty of them.
# Scan only after the Cross-Chunk Issues Found anchor, ignoring "None found" /
# N/A placeholders.
#
# A list item is CONTENT, never a subsection header. That ordering is load-
# bearing: the header probes below match an emoji plus a severity word, and a
# model that writes its findings as `- **H1)** 🔴 Critical: …` instead of under
# the template's `🔴 **Critical Issues**` heading matches them too — so the
# earlier version consumed each blocking bullet AS a heading and counted zero.
# A bullet that carries a 🔴/🟠 marker itself is therefore counted whatever
# section it sits in; over-counting can only escalate, which is the safe
# direction for a backstop.
holistic_blocking=0
if [ -n "$holistic" ] && [ -s "$holistic" ]; then
  holistic_blocking=$(
    awk '
      BEGIN { sec = ""; n = 0 }
      /^\*\*Cross-Chunk Issues Found:\*\*/ { started = 1; next }
      !started { next }
      /^[[:space:]]*[-*][[:space:]]/ {
        line = $0
        # Strip markdown emphasis for the placeholder probe.
        gsub(/[`*_"]/, "", line)
        lower = tolower(line)
        if (lower ~ /none found/ || lower ~ /^[-* ]*n\/?a[.! ]*$/ || lower ~ /not applicable/) next
        self_blocking = 0
        if ($0 ~ /🔴/ || $0 ~ /🟠/) self_blocking = 1
        else if (lower ~ /^[-* ]*(h[0-9]+\)[ ]*)?(critical|high( priority)?)[: ,.-]/) self_blocking = 1
        if (sec == "block" || self_blocking) n++
        next
      }
      /🔴/ && /Critical/ { sec = "block"; next }
      /🟠/ && /High/     { sec = "block"; next }
      /🟡/ && /Medium/   { sec = ""; next }
      /🔵/               { sec = ""; next }
      /^## /             { sec = ""; next }
      # A bold label line ("**Additional Analysis:**", "**Overall Assessment:**")
      # ends the severity subsections; without this a template that omits the
      # Medium/Low headings leaves sec=="block" over unrelated prose bullets.
      /^\*\*[^*]/        { sec = ""; next }
      END { print n + 0 }
    ' "$holistic" 2>/dev/null || echo 0
  )
  # Trim whitespace so arithmetic comparisons never see a trailing newline
  # ("integer expression expected" under set -e / strict shells).
  holistic_blocking="$(printf '%s' "$holistic_blocking" | tr -d '[:space:]')"
fi
# Coerce empty/non-numeric to 0 so -gt/-eq never choke.
case "$crit" in ''|*[!0-9]*) crit=0 ;; esac
case "$high" in ''|*[!0-9]*) high=0 ;; esac
case "$med" in ''|*[!0-9]*) med=0 ;; esac
case "$low" in ''|*[!0-9]*) low=0 ;; esac
case "$pre" in ''|*[!0-9]*) pre=0 ;; esac
case "$holistic_blocking" in ''|*[!0-9]*) holistic_blocking=0 ;; esac

original_action="$(printf '%s' "${SYNC_ORIGINAL_ACTION:-}" \
  | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z_')"

if [ "$crit" -gt 0 ] || [ "$high" -gt 0 ] || [ "$holistic_blocking" -gt 0 ]; then
  decision="request_changes"
  decision_label="REQUEST CHANGES"
  action="REQUEST_CHANGES"
  if [ "$holistic_blocking" -gt 0 ] && [ "$crit" -eq 0 ] && [ "$high" -eq 0 ]; then
    rationale="Following policy: 0 critical and 0 high priority issues in the structured summary, but ${holistic_blocking} holistic cross-chunk Critical/High issue(s) remain — requesting changes."
  else
    rationale="Following policy: ${crit} critical and ${high} high priority issue(s) found - requesting changes."
  fi
elif [ "$original_action" = "comment" ]; then
  # No blocker in the merged set, but the orchestrator deliberately declined to
  # approve. Removing a block is sanctioned (issue #125); manufacturing an
  # APPROVE is not — that is a review state the orchestrator never claimed.
  decision="comment"
  decision_label="COMMENT"
  action="COMMENT"
  rationale="Following policy: 0 critical and 0 high priority issue(s) found; ${med} medium and ${low} low priority issue(s) remain - commenting (the orchestrator's non-blocking verdict is preserved)."
else
  decision="approve"
  decision_label="APPROVE"
  action="APPROVE"
  rationale="Following policy: Only ${med} medium and ${low} low priority issue(s) found - approving."
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Rewrite count lines wherever they appear; rewrite Decision / Rationale /
# MACHINE_READABLE_ACTION only inside the Recommendation section so a quoted
# example elsewhere cannot be clobbered.
awk -v crit="$crit" -v high="$high" -v med="$med" -v low="$low" -v pre="$pre" \
    -v decision_label="$decision_label" -v action="$action" -v rationale="$rationale" '
  # Replace ONLY the number that follows a count label, keeping the bullet
  # prefix, any closing emphasis on a bold label, and any trailing note.
  function set_count(line, label, val,    i, head, tail, closing) {
    i = index(line, label)
    if (i == 0) return line
    head = substr(line, 1, i + length(label) - 1)
    tail = substr(line, i + length(label))
    closing = ""
    if (match(tail, /^[*_]+/)) {
      closing = substr(tail, 1, RLENGTH)
      tail = substr(tail, RLENGTH + 1)
    }
    # Drop the leading whitespace plus the old value: a number, or an unfilled
    # `[number - …]` template placeholder.
    sub(/^[[:space:]]*(\[[^]]*\]|[0-9]+)?/, "", tail)
    return head closing " " val tail
  }

  BEGIN { in_rec = 0 }
  /^## 🎯 Recommendation/ { in_rec = 1 }
  in_rec && /^## / && $0 !~ /^## 🎯 Recommendation/ { in_rec = 0 }

  {
    if ($0 ~ /Count of 🔴 Critical Issues:/) {
      print set_count($0, "Count of 🔴 Critical Issues:", crit); next
    }
    if ($0 ~ /Count of 🟠 High Priority Issues:/) {
      print set_count($0, "Count of 🟠 High Priority Issues:", high); next
    }
    if ($0 ~ /Count of 🟡 Medium Priority Issues:/) {
      print set_count($0, "Count of 🟡 Medium Priority Issues:", med); next
    }
    if ($0 ~ /Count of 🔵 Low Priority Issues:/) {
      print set_count($0, "Count of 🔵 Low Priority Issues:", low); next
    }
    if ($0 ~ /Count of 🗂️ Pre-existing issues:/) {
      print set_count($0, "Count of 🗂️ Pre-existing issues:", pre); next
    }
    if (in_rec && $0 ~ /^\*\*Decision:\*\*/) {
      print "**Decision:** " decision_label
      next
    }
    if (in_rec && $0 ~ /^\*\*Rationale:\*\*/) {
      print "**Rationale:** " rationale
      next
    }
    if (in_rec && $0 ~ /^\*\*MACHINE_READABLE_ACTION:\*\*/) {
      print "**MACHINE_READABLE_ACTION:** " action
      next
    }
    print
  }
' "$summary" > "$tmp"

if [ ! -s "$tmp" ]; then
  exit 1
fi
mv "$tmp" "$summary"
trap - EXIT

# Surface the sync on stderr so CI logs show why the orchestrator's numbers moved.
echo "Synced Recommendation from merged findings: critical=${crit} high=${high} medium=${med} low=${low} pre_existing=${pre} holistic_blocking=${holistic_blocking} original=${original_action:-unknown} → ${action}" >&2

printf '%s\n' "$decision"
exit 0
