#!/bin/bash
# render-findings-summary.sh — render the posted review's `## 🔍 Issues Summary`
# from the merged findings document (LADR-055). Writes markdown to stdout.
#
# Usage: render-findings-summary.sh <merged_json> [failed_chunks] [total_chunks]
#
#   failed_chunks and total_chunks are optional integers sourced from the
#   same flag-file counters as the LADR-036 coverage banner. They are not
#   derived from the merged JSON — LADR-031's channel is the flag files,
#   full stop.
#
# The output must stay byte-compatible with the grammar three consumers parse:
#
#   - scripts/eval/lib/score-review.sh   — `[VERIFIED]` plus the severity keyword
#                                          in the label (the text before the
#                                          first colon), "None found" as the
#                                          empty placeholder.
#   - lib/extract-ai-analyse-scope.sh    — `### 🟡 Medium Priority Issues` and
#                                          `### 🔵 Low Priority` section headers,
#                                          captured until the next `###`/`##`.
#   - lib/select-ai-analyse-artifact.sh  — `## 🔍 Issues Summary` identifies the
#                                          body as a gate artifact.
#
# What this adds on top of that grammar is additive only: a stable `#` number and
# a chunk back-reference per finding. Changing an emoji, a section header, or the
# position of the `[VERIFIED]` tag breaks a consumer silently — the review still
# posts, the autonomous fixer just stops finding anything to fix.
set -uo pipefail

merged="${1:-}"
failed_chunks="${2:-0}"
total_chunks="${3:-0}"
if [ -z "$merged" ] || [ ! -s "$merged" ]; then
  exit 1
fi
command -v jq >/dev/null 2>&1 || exit 1
jq -e '.status == "complete"' "$merged" >/dev/null 2>&1 || exit 1

jq -r '
  def clean: gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "");

  def sev_emoji:
    if . == "critical" then "🔴"
    elif . == "high"   then "🟠"
    elif . == "medium" then "🟡"
    else "🔵" end;

  def sev_label:
    if . == "critical" then "Critical"
    elif . == "high"   then "High Priority"
    elif . == "medium" then "Medium Priority"
    else "Low Priority" end;

  def chunk_ref:
    if (. | length) == 0 then ""
    elif (. | length) == 1 then " (chunk #\(.[0]))"
    else " (chunks " + ([.[] | "#\(.)"] | join(", ")) + ")"
    end;

  # One finding, one bullet. The label — everything before the first colon —
  # carries the number, the emoji, the [VERIFIED]/[SPECULATIVE] tag and the
  # severity keyword, in that order, because that is what score-review.sh reads.
  def bullet:
    "- **#\(.["#"])** \(.severity | sev_emoji) "
    + (if .verified == true then "[VERIFIED]" else "[SPECULATIVE]" end)
    + " \(.severity | sev_label): \(.title | clean)"
    + " — `\(.file)"
    + ":\(.line)"
    + "`"
    + (.chunks // [] | chunk_ref)
    + (if (.why_it_matters // "") != "" then "\n  - \(.why_it_matters | clean)" else "" end);

  # Residual risks and testing gaps render into the Medium tier as ordinary
  # bullets. They are real work the reviewer identified, and the Medium section
  # is where `ai-analyse` looks — leaving them in the merged JSON only meant
  # nobody, human or agent, ever saw them.
  #
  # Deliberately WITHOUT the [VERIFIED] tag. `eval/lib/score-review.sh` counts a
  # line as a flag only when its label carries `[VERIFIED]` *and* a severity
  # keyword; precision over the DR corpus is zero-tolerance, so tagging these
  # would let an honest reviewer note such as "no test covers the new branch"
  # fail a must-not-flag fixture. Untagged, they are visible to a reader and to
  # `extract-ai-analyse-scope.sh` (which only needs a non-empty, non-"None found"
  # line) while staying out of the flag count. They also carry no file:line —
  # they are not located defects, and inventing a location would be worse.
  def soft_bullet($kind):
    "- 🟡 \($kind): \(. | clean)";

  def soft_items:
    [ (.testing_gaps // [])[] | soft_bullet("Testing gap") ]
    + [ (.residual_risks // [])[] | soft_bullet("Residual risk") ];

  def section($sev; $heading):
    "### \($heading)",
    "",
    ( ( [ .findings[] | select(.severity == $sev) ] | map(bullet) )
      + (if $sev == "medium" then soft_items else [] end)
      | if length == 0 then ["None found"] else . end
      | .[] ),
    "";

  "## 🔍 Issues Summary",
  "",
  "**Note:** Findings are deduplicated across chunks and numbered stably (`#1`, `#2`, …); the chunk reference on each one names the section to open under [📂 View detailed reviews below](#-view-detailed-reviews-click-to-expand) for that reviewer’s full reasoning.",
  "",
  section("critical"; "🔴 Critical Issues"),
  section("high"; "🟠 High Priority Issues"),
  section("medium"; "🟡 Medium Priority Issues"),
  section("low"; "🔵 Low Priority / Nitpicks"),

  # Pre-existing findings are reported, never counted. They are not defects this
  # PR introduced, so surfacing them among the actionable set would make every
  # review of a legacy file look like a regression.
  ( if (.pre_existing_findings | length) > 0 then
      ( "### 🗂️ Pre-existing (not introduced by this PR)",
        "",
        ( .pre_existing_findings[]
          | "- \(.severity | sev_emoji) \(.severity | sev_label): \(.title | clean) — `\(.file):\(.line)`"
            + (.chunks // [] | chunk_ref) ),
        "" )
    else empty end ),

  # Coverage. Suppression that nobody can see is suppression nobody should
  # trust, so this block renders even when every count is zero.
  "### 📊 Coverage",
  "",
  "- **Duplicates merged across chunks:** \(.merged_duplicates)",
  "- **Demoted for missing quoted evidence:** \(.demoted_no_quote) (claimed confidence ≥ 75 without quoting the motivating line, stepped down to 50)",
  # The buckets must be ordered HERE, not in merge-findings.py. Its keys are
  # strings (`str(confidence)`) and it serialises with `sort_keys=True`, which
  # re-sorts every nested object lexicographically — so 0, 100, 25, 50, 75.
  # Sorting the dict on the Python side is a no-op the serializer undoes; the
  # numeric order has to be re-imposed on read.
  "- **Suppressed below the actionable anchor:** \(.suppressed_findings | length)"
    + ( if (.suppressed_by_confidence | length) > 0
        then " (" + ([ .suppressed_by_confidence | to_entries | sort_by(.key | tonumber) | .[] | "confidence \(.key): \(.value)" ] | join(", ")) + ")"
        else "" end ),
  "- **Malformed and dropped:** \(.malformed_findings) finding(s), \(.malformed_returns) chunk document(s)",
  "- **Failed or timed-out chunks:** \($failed_chunks) of \($total_chunks)",
  "- **Pre-existing findings (partitioned out of verdict):** \(.pre_existing_findings | length)",
  "- **Soft buckets — residual risks:** \(.residual_risks | length)",
  "- **Soft buckets — testing gaps:** \(.testing_gaps | length)",
  "",
  "Suppression is mechanical, not editorial: a finding below confidence 75 is a verified nitpick or an unverified guess, and only 🔴 Critical is exempt so an important-but-uncertain blocker is never dropped silently.",
  ""
' --arg failed_chunks "$failed_chunks" --arg total_chunks "$total_chunks" "$merged"
