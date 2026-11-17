#!/bin/bash
# render-structural-risk.sh — the presentation-only "Structural Risk (graph)"
# block of the posted report (HLD-003 LADR-06).
#
# Usage: bash render-structural-risk.sh <graph_detect_changes.json> [graph_state.json]
# Prints the block wrapped in begin/end markers, or nothing. Always exits 0.
#
# Gated by OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK (default 0) and by
# GRAPH_ANALYSIS_AVAILABLE=true. Absent, empty or unparseable graph data → no
# block. The block is outside the findings document: it never carries a
# numbered line, a severity emoji or label, or `#` followed by digits, so every
# consumer parser reads the same findings, counts and action with or without it.
#
# The markers (directly under the heading) let the posted-body size ladder
# (run-review.sh Step 20) drop the whole block before any truncation can cut it.
set -u

GRAPH_JSON="${1:-}"
STATE="${2:-}"

flag_on() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'
}

flag_on "${OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK:-0}" || exit 0
[ "${GRAPH_ANALYSIS_AVAILABLE:-}" = "true" ] || exit 0
[ -n "$GRAPH_JSON" ] && [ -s "$GRAPH_JSON" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' "$GRAPH_JSON" >/dev/null 2>&1 || exit 0

churn=""
if [ -n "$STATE" ] && [ -s "$STATE" ]; then
  churn="$(jq -r '.churn_status // "" | strings' "$STATE" 2>/dev/null || true)"
fi

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="${root%/}/"

body="$(jq -r --arg root "$root" --arg churn "$churn" '
  def safe_text:
    type == "string" and length > 0 and
    (test("[\\x00-\\x1f\\x7f`]|#[0-9]|🔴|🟠|🟡|🔵|(?i:issues found|###[[:space:]]*file:)") | not);
  def relpath:
    select(safe_text) | ltrimstr($root) |
    select((test("^/|^[A-Za-z]:|(^|/)\\.\\.?($|/)") | not));
  def short:
    select(safe_text) | ltrimstr($root) |
    if test("::") and startswith("/") then sub("^[^:]*::"; "") else . end |
    select(startswith("/") | not);
  def num: if type == "number" then . else null end;
  def r2: (. * 100 | round) / 100 | tostring;
  ((.changed_functions // []) | if type == "array" then . else [] end) as $cf
  | ((.test_gaps // []) | if type == "array" then . else [] end) as $gaps
  | ((.removed_symbols // []) | if type == "array" then . else [] end) as $removed
  | ((.affected_flows // []) | if type == "array" then length else 0 end) as $flows
  | ($cf | map(.risk_score | num) | map(select(. != null))) as $risks
  | (.risk_score | num) as $overall
  | ($gaps | map(select(.coverage == "indirect")) | length) as $indirect
  | (($gaps | length) - $indirect) as $direct
  | ($cf | map(.file_path | relpath?) | unique | length) as $files
  | ($removed
      | map(select((.used_by_total | num) != null and .used_by_total > 0))
      | map(((.file // "") | ltrimstr($root)) as $file
            | { f: ((.file // "") | relpath?), l: (.old_line_start | num),
                n: ((.qualified_name // .name // "") | short? | ltrimstr($file + "::")),
                u: .used_by_total })
      | map(select(.f != null and .l != null and .n != null))
      | .[:5]) as $still_used
  | (if $churn == "ok" then "included"
     elif $churn == "unavailable" then "unavailable"
     elif $churn == "off" then "not requested"
     else "not reported" end) as $churn_text
  | [
      "- **Overall risk:** "
        + (if $overall != null then ($overall | r2)
           elif ($risks | length) > 0 then (($risks | max) | r2) + " (highest changed function)"
           else "not reported" end)
        + " · change frequency " + $churn_text,
      "- **Changed functions:** \($cf | length) across \($files) file(s); \($risks | map(select(. >= 0.7)) | length) at risk 0.7 or above",
      "- **Affected flows:** \($flows)",
      "- **Test gaps (graph-inferred):** \($direct) with no test edge found, \($indirect) reached only through a caller",
      ( if ($still_used | length) > 0 then
          "- **Removed but still referenced (graph):** "
            + ($still_used | map("`\(.f):\(.l)` \(.n) (\(.u) user\(if .u == 1 then "" else "s" end))") | join(", "))
        else empty end )
    ] | .[]
' "$GRAPH_JSON" 2>/dev/null)" || exit 0
[ -n "$body" ] || exit 0

# The heading comes first so a section-bounded parser stops on it exactly as it
# stopped on the next heading before; the markers sit inside the section.
printf '%s\n' \
  '## 🧭 Structural Risk (graph)' \
  '<!-- ai-review-report:structural-risk:begin -->' \
  '' \
  '<details>' \
  '<summary>Structural hints from the code graph — not findings, not counted, never part of the verdict</summary>' \
  '' \
  "$body" \
  '' \
  'Graph edges are inferred and can be stale or incomplete; a missing test edge does not prove a missing test.' \
  '' \
  '</details>' \
  '<!-- ai-review-report:structural-risk:end -->'
exit 0
