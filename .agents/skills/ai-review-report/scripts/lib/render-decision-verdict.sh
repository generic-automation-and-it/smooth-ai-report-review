#!/bin/bash
# render-decision-verdict.sh — put the decision model's PR-level evaluation next
# to the posted verdict (LADR-093).
#
# Usage: render-decision-verdict.sh <merged_json> <summary_md>
#
# Inserts ONE line directly below the `**Decision:**` line of the
# `## 🎯 Recommendation` section (or below the heading when the decision line is
# missing), so a human or an agent reading the verdict sees the evaluation
# beside it:
#
#   **Decision model:** block-merge probability 83% · overall risk Moderate
#   (2.4 of 4) · dominant risk correctness (66%) — informational; the decision
#   above follows the review policy.
#
# When a BLOCKING finding (critical or high) was judged a likely re-raise of the
# PR's own Skip Areas, or likely allowed by a project rule (probability at or
# above the decision threshold), that is named here too — it is the case where
# a reader most needs to question the verdict above:
#
#   … · finding 3 likely re-raises a Skip Areas item (88%) · finding 2 likely
#   allowed by a project rule (93%) — informational; …
#
# Informational only: it never edits the decision, the counts or
# MACHINE_READABLE_ACTION, and it deliberately contains none of the words the
# fallback text parser in aggregate-reviews.sh looks for ("approve",
# "request changes"), so it can never be mistaken for a verdict. No `#`+digits
# (LADR-067).
#
# Behind the feature flag: does nothing unless OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS
# is truthy AND the merged document carries PR-level answers. Idempotent, and
# best-effort: any problem leaves <summary_md> untouched and exits 0.
set -uo pipefail

merged="${1:-}"
summary="${2:-}"

printf '%s' "${OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS:-0}" | tr '[:upper:]' '[:lower:]' \
  | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on' || exit 0
[ -n "$merged" ] && [ -s "$merged" ] && [ -n "$summary" ] && [ -f "$summary" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
grep -q '^\*\*Decision model:\*\*' "$summary" && exit 0

line="$(jq -r '
  def pct: "\((. * 100) | round)%";
  # context_note(key; one; many): blocking findings whose answer to <key> is at
  # or above the threshold, as one phrase ("finding 3 … (88%)" or "findings 3,
  # 5 … (88%, 71%)"), or empty.
  def context_note($f; $min; key; $one; $many):
    [ $f[] | select(.severity == "critical" or .severity == "high")
      | select(((.decisions // {}) | key // null) != null and ((.decisions | key) >= $min))
      | { n: .["#"], p: (.decisions | key) } ]
    | if length == 0 then empty
      elif length == 1 then "finding \(.[0].n) \($one) (\(.[0].p | pct))"
      else "findings \(map(.n | tostring) | join(", ")) \($many) (\(map(.p | pct) | join(", ")))" end;
  (.findings // []) as $f
  | .decisions_summary // empty
  | (.min_probability // 0.5) as $min
  | [ context_note($f; $min; .previously_skipped; "likely re-raises a Skip Areas item"; "likely re-raise Skip Areas items"),
      context_note($f; $min; .sanctioned; "likely allowed by a project rule"; "likely allowed by project rules") ] as $ctx
  | select(.block_merge != null or .overall_risk != null or .dominant_risk != null or ($ctx | length) > 0)
  | [ ( if .block_merge != null then "block-merge probability \(.block_merge | pct)" else empty end ),
      ( if .overall_risk != null then
          ((.overall_risk.legend // {})[(.overall_risk.score | round | tostring)] // "" | split(":")[0]) as $lvl
          | "overall risk " + (if $lvl != "" then "\($lvl) " else "" end)
            + "(\(.overall_risk.score * 10 | round / 10) of \(((.overall_risk.legend // {}) | length) - 1))"
        else empty end ),
      ( if .dominant_risk != null then
          "dominant risk \(.dominant_risk.choice)"
          + (if .dominant_risk.confidence != null then " (\(.dominant_risk.confidence | pct))" else "" end)
        else empty end ),
      $ctx[] ]
  | select(length > 0)
  | "**Decision model:** " + join(" · ")
    + " — informational; the decision above follows the review policy."
' "$merged" 2>/dev/null)"
[ -n "$line" ] || exit 0

tmp="$(mktemp 2>/dev/null)" || exit 0
awk -v line="$line" '
  !done && /^\*\*Decision:\*\*/ { print; print ""; print line; print ""; done = 1; next }
  { print }
  END { if (!done) exit 3 }
' "$summary" > "$tmp"
rc=$?
if [ "$rc" -eq 3 ]; then
  # No decision line: place it under the Recommendation heading instead.
  awk -v line="$line" '
    !done && /^## 🎯 Recommendation/ { print; print ""; print line; print ""; done = 1; next }
    { print }
    END { if (!done) exit 3 }
  ' "$summary" > "$tmp"
  rc=$?
fi
if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
  mv "$tmp" "$summary"
  echo "🎯 Decision-model verdict line added next to the Recommendation (LADR-093)"
else
  rm -f "$tmp"
fi
exit 0
