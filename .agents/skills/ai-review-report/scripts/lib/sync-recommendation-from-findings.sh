#!/bin/bash
# sync-recommendation-from-findings.sh — rewrite Recommendation counts + decision
# from the post-validation merged findings document (issue #125 / LADR-055).
#
# Usage:
#   sync-recommendation-from-findings.sh <merged_json> <summary_md> [holistic_md]
#
# Edits <summary_md> in place. Prints the machine-readable decision to stdout
# (request_changes | approve). Exit 0 on success, 1 when inputs are unusable
# (caller keeps the orchestrator's recommendation).
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
# Decision rule (same tree the orchestrator prompt states):
#   critical > 0 OR high > 0  → request_changes
#   else                      → approve
# Holistic Critical/High items (no per-chunk sidecar entry) still block: when
# the merged set has no critical/high, a non-empty Critical/High bullet under
# Cross-Chunk Issues Found in [holistic_md] forces request_changes. Failed
# chunks are handled by the caller (LADR-031/036), not here.
#
# Count lines rewritten (when present):
#   - Count of 🔴 Critical Issues: N
#   - Count of 🟠 High Priority Issues: N
#   - Count of 🟡 Medium Priority Issues: N
#   - Count of 🔵 Low Priority Issues: N
#   - Count of 🗂️ Pre-existing issues: N
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
# Scan only after the Cross-Chunk Issues Found anchor, only the Critical and
# High subsections, ignoring "None found" / N/A placeholders.
holistic_blocking=0
if [ -n "$holistic" ] && [ -s "$holistic" ]; then
  holistic_blocking=$(
    awk '
      BEGIN { sec = ""; n = 0 }
      /^\*\*Cross-Chunk Issues Found:\*\*/ { started = 1; next }
      !started { next }
      /🔴/ && /Critical/ { sec = "block"; next }
      /🟠/ && /High/     { sec = "block"; next }
      /🟡/ && /Medium/   { sec = ""; next }
      /🔵/               { sec = ""; next }
      /^## /             { sec = ""; next }
      sec == "block" && /^[-*] / {
        line = $0
        # Strip markdown emphasis for the placeholder probe.
        gsub(/[`*_"]/, "", line)
        lower = tolower(line)
        if (lower ~ /none found/ || lower ~ /^[-* ]*n\/?a[.! ]*$/ || lower ~ /not applicable/) next
        n++
      }
      END { print n + 0 }
    ' "$holistic" 2>/dev/null || echo 0
  )
fi

if [ "${crit:-0}" -gt 0 ] || [ "${high:-0}" -gt 0 ] || [ "${holistic_blocking:-0}" -gt 0 ]; then
  decision="request_changes"
  decision_label="REQUEST CHANGES"
  action="REQUEST_CHANGES"
  if [ "${holistic_blocking:-0}" -gt 0 ] && [ "${crit:-0}" -eq 0 ] && [ "${high:-0}" -eq 0 ]; then
    rationale="Following policy: 0 critical and 0 high priority issues in the structured summary, but ${holistic_blocking} holistic cross-chunk Critical/High issue(s) remain — requesting changes."
  else
    rationale="Following policy: ${crit} critical and ${high} high priority issue(s) found - requesting changes."
  fi
else
  decision="approve"
  decision_label="APPROVE"
  action="APPROVE"
  rationale="Following policy: Only ${med} medium and ${low} low priority issue(s) found - approving."
fi

tmp="$(mktemp)"
# Rewrite count lines wherever they appear; rewrite Decision / Rationale /
# MACHINE_READABLE_ACTION only inside the Recommendation section so a quoted
# example elsewhere cannot be clobbered.
awk -v crit="$crit" -v high="$high" -v med="$med" -v low="$low" -v pre="$pre" \
    -v decision_label="$decision_label" -v action="$action" -v rationale="$rationale" '
  BEGIN { in_rec = 0 }
  /^## 🎯 Recommendation/ { in_rec = 1 }
  in_rec && /^## / && $0 !~ /^## 🎯 Recommendation/ { in_rec = 0 }

  {
    if ($0 ~ /Count of 🔴 Critical Issues:/) {
      sub(/Count of 🔴 Critical Issues:[[:space:]].*/, "Count of 🔴 Critical Issues: " crit)
      print
      next
    }
    if ($0 ~ /Count of 🟠 High Priority Issues:/) {
      sub(/Count of 🟠 High Priority Issues:[[:space:]].*/, "Count of 🟠 High Priority Issues: " high)
      print
      next
    }
    if ($0 ~ /Count of 🟡 Medium Priority Issues:/) {
      sub(/Count of 🟡 Medium Priority Issues:[[:space:]].*/, "Count of 🟡 Medium Priority Issues: " med)
      print
      next
    }
    if ($0 ~ /Count of 🔵 Low Priority Issues:/) {
      sub(/Count of 🔵 Low Priority Issues:[[:space:]].*/, "Count of 🔵 Low Priority Issues: " low)
      print
      next
    }
    if ($0 ~ /Count of 🗂️ Pre-existing issues:/) {
      # Keep any trailing note after the number (the template appends
      # "— these do NOT block the PR"). Portable: no gawk-only match() 3-arg form.
      trail = $0
      sub(/^.*Count of 🗂️ Pre-existing issues:[[:space:]]*[0-9]*/, "", trail)
      print "Count of 🗂️ Pre-existing issues: " pre trail
      next
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
  rm -f "$tmp"
  exit 1
fi
mv "$tmp" "$summary"

# Surface the sync on stderr so CI logs show why the orchestrator's numbers moved.
echo "Synced Recommendation from merged findings: critical=${crit} high=${high} medium=${med} low=${low} pre_existing=${pre} holistic_blocking=${holistic_blocking} → ${action}" >&2

printf '%s\n' "$decision"
exit 0
