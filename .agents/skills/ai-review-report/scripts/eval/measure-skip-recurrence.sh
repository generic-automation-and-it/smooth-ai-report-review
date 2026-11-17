#!/bin/bash
# measure-skip-recurrence.sh — how many autonomous ai-analyse SKIPs reappear as
# findings in the next gate review (HLD-006 NFR-04). Report-only: it never
# gates a run and never writes to the PR.
#
# Usage: measure-skip-recurrence.sh <analyse-summary.md> <next-review.md>
#        measure-skip-recurrence.sh --pr <N> [--repo owner/name]
#
# Join: each SKIP row of the `## ai-analyse auto-fix summary` table
# (`| # | Decision | Priority | File | Summary | Reason |`) against the numbered
# findings of the next gate review (lib/review-findings-to-json.sh) on file +
# normalised summary text. The table carries no line number, so the line is not
# part of the key. Normalisation: lowercase, collapse whitespace runs to one
# space, strip trailing punctuation; exact equality only, no fuzzy matching.
#
# A `—`/`-` file (R/T rows), a row matching nothing, and a row matching more
# than one finding are counted in `unmatched_skips` — never dropped silently,
# never double-counted. When either side is missing the result is
# {"status":"unavailable"}, never a zero.
#
# --pr reads the PR timeline: the latest `## ai-analyse auto-fix summary`
# comment, and the first gate review (an Issues Summary body) submitted after it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/../lib/review-findings-to-json.sh"

unavailable() {
  jq -cn --arg reason "$1" '{status: "unavailable", reason: $reason}'
  exit 0
}

command -v jq >/dev/null 2>&1 || { echo '{"status":"unavailable","reason":"jq missing"}'; exit 0; }

if [ "${1:-}" = "--pr" ]; then
  pr="${2:-}"; repo="${GITHUB_REPOSITORY:-}"
  [ "${3:-}" = "--repo" ] && repo="${4:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "usage: $0 --pr <N> [--repo owner/name]" >&2; exit 2; }
  command -v gh >/dev/null 2>&1 || unavailable "gh missing"
  [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$repo" ] || unavailable "repository unknown"
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  gh api --paginate "repos/$repo/issues/$pr/comments?per_page=100" > "$work/comments.json" 2>/dev/null \
    || unavailable "PR comments unreadable"
  gh api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100" > "$work/reviews.json" 2>/dev/null \
    || unavailable "PR reviews unreadable"
  jq -s 'add // [] | map(select((.body // "") | test("(^|\n)## ai-analyse auto-fix summary"))) | sort_by(.created_at) | last // empty' \
    "$work/comments.json" > "$work/summary.json"
  [ -s "$work/summary.json" ] || unavailable "no ai-analyse summary comment"
  since="$(jq -r '.created_at' "$work/summary.json")"
  jq -r '.body' "$work/summary.json" > "$work/summary.md"
  jq -rs --arg since "$since" 'add // []
    | map(select((.body // "") | test("(^|\n)## 🔍 Issues Summary")) | select((.submitted_at // "") > $since))
    | sort_by(.submitted_at) | first | .body // empty' "$work/reviews.json" > "$work/review.md"
  [ -s "$work/review.md" ] || unavailable "no gate review after the ai-analyse summary"
  exec bash "${BASH_SOURCE[0]}" "$work/summary.md" "$work/review.md"
fi

summary="${1:-}"; review="${2:-}"
[ -n "$summary" ] && [ -s "$summary" ] || unavailable "ai-analyse summary missing"
[ -n "$review" ] && [ -s "$review" ] || unavailable "next review missing"
grep -q '^## ai-analyse auto-fix summary' "$summary" || unavailable "not an ai-analyse summary"

findings="$(bash "$PARSER" "$review" 2>/dev/null | jq -c '[.findings[]? | {file, title}]' 2>/dev/null)"
[ -n "$findings" ] || unavailable "next review unparseable"
grep -q '^## 🔍 Issues Summary' "$review" || unavailable "next review has no Issues Summary"

# The parser reads only the rendered structured-findings grammar. An Issues
# Summary written in any other shape (the orchestrator's own prose, an older
# format) parses to fewer findings than it lists, and joining against that
# would report a false zero. Count the list items under the severity headings —
# excluding "None found", the R/T/P bullets and indented sub-bullets — and give
# up when the parser saw fewer. A genuinely clean review lists none.
listed="$(awk '
  /^## / { in_issues = ($0 ~ /^## 🔍 Issues Summary/); in_sev = 0; next }
  in_issues && /^### / { in_sev = ($0 ~ /^### (🔴|🟠|🟡|🔵)/); next }
  in_issues && in_sev && /^([0-9]+\.|[-*]) / && !/None found/ && !/^- \*\*[RTPH][0-9]+\)\*\*/ { n++ }
  END { print n + 0 }' "$review")"
parsed="$(jq 'length' <<< "$findings")"
[ "$listed" -le "$parsed" ] || unavailable "next review lists $listed finding(s) but only $parsed parse in the structured grammar"

# SKIP rows → {file, summary}. Cells are trimmed and stripped of bold/code marks.
skips="$(awk -F'|' '
  function clean(s) { gsub(/\*\*|`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
  /^[[:space:]]*\|/ && NF >= 8 {
    d = toupper(clean($3))
    if (d == "SKIP") printf "%s\t%s\n", clean($5), clean($6)
  }' "$summary" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {file: .[0], summary: .[1]})')"

jq -cn --argjson skips "$skips" --argjson findings "$findings" '
  def norm: ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | sub("[[:punct:]]+$"; "");
  ($findings | map({file, t: (.title // "" | norm)})) as $f
  | [ $skips[]
      | . as $s
      | (if ($s.file == "—" or $s.file == "-" or $s.file == "") then -1
         else ($f | map(select(.file == $s.file and .t == ($s.summary | norm))) | length) end) as $hits
      | $s + {hits: $hits} ]
  | { status: "measured",
      skips: length,
      reappeared: (map(select(.hits == 1)) | length),
      unmatched_skips: (map(select(.hits != 1)) | length),
      reappeared_rows: (map(select(.hits == 1) | {file, summary})) }'
