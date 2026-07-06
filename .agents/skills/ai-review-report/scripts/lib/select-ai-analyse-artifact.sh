#!/usr/bin/env bash
# Build a unified descending timeline of gate-authored PR reviews and issue
# comments, then select the artifact that should drive ai-analyse.
#
# Input:
#   $1  owner/repo
#   $2  PR number
#   $3  max_incremental cap (default 3, must be positive integer)
#   $4  path to write the selected artifact body (optional)
#
# Output (stdout): JSON
#   {
#     "act": true|false,
#     "skip_reason": "..."|null,
#     "artifact_id": "..."|null,
#     "artifact_source": "review"|"comment"|null,
#     "incremental_count": 0,
#     "max_incremental": 3,
#     "body_path": "..."|null
#   }
#
# Exit 0 in all normal branches; non-zero only on usage/IO errors.
set -euo pipefail

repo="${1:-}"
pr_number="${2:-}"
max_incremental="${3:-3}"
body_out_path="${4:-}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ -z "$repo" ] || [ -z "$pr_number" ]; then
  echo "usage: $0 <owner/repo> <pr_number> [max_incremental] [body_out_path]" >&2
  exit 64
fi

case "$max_incremental" in
  ''|*[!0-9]*) max_incremental=3 ;;
esac
[ "$max_incremental" -gt 0 ] || max_incremental=3

# Fetch both sources with pagination. Combine pages (gh api --paginate emits
# one JSON array per page) and fall back to [] on any error.
fetch_paginated() {
  local endpoint="$1"
  local result
  if ! result="$(gh api --paginate "${endpoint}" 2>/dev/null | jq -s 'add // []')"; then
    result='[]'
  fi
  printf '%s' "$result"
}

reviews_file="$tmp_dir/reviews.json"
comments_file="$tmp_dir/comments.json"
fetch_paginated "repos/${repo}/pulls/${pr_number}/reviews" > "$reviews_file"
fetch_paginated "repos/${repo}/issues/${pr_number}/comments" > "$comments_file"

# Normalize both sources into a single timeline. Reviews use .submitted_at,
# issue comments use .created_at. Keep only github-actions[bot] entries.
timeline="$(jq -n \
  --slurpfile reviews "$reviews_file" \
  --slurpfile comments "$comments_file" \
  '
    [
      (($reviews[0] // [])[]? | {ts: .submitted_at, id: (.id | tostring), source: "review", author: .user.login, body: .body}),
      (($comments[0] // [])[]? | {ts: .created_at, id: (.id | tostring), source: "comment", author: .user.login, body: .body})
    ]
    | map(select(.author == "github-actions[bot]" and .body != null))
    | sort_by(.ts)
    | reverse
  ')"

# Classify each entry. Actionable artifacts carry the structured Issues Summary
# that extract-ai-analyse-scope.sh expects. Skip-incremental comments are the
# non-actionable cycle artifacts posted by the gate's blocked-incremental path.
classified="$(printf '%s' "$timeline" | jq '
  map(. + {
    is_gate_report: (
      (.body | test("^#+ 🤖 (Gemini CLI|OpenCode CLI) Code Review"; "m"))
    ),
    is_actionable: (
      (.body | test("## 🔍 Issues Summary"))
    ),
    is_skip_incremental: (
      (.body | test("Skipping[^\\n]*INCREMENTAL[^\\n]*review"; "i"))
      and (.body | test("Existing blocking review"))
    )
  })
')"

artifacts="$(printf '%s' "$classified" | jq '[.[] | select(.is_gate_report and (.is_actionable or .is_skip_incremental))]')"
latest="$(printf '%s' "$artifacts" | jq 'first // empty')"

emit() {
  jq -n \
    --argjson act "$1" \
    --arg skip_reason "${2:-}" \
    --arg artifact_id "${3:-}" \
    --arg artifact_source "${4:-}" \
    --argjson incremental_count "${5:-0}" \
    --argjson max_incremental "$max_incremental" \
    --arg body_path "${6:-}" \
    --arg artifact_ts "${7:-}" \
    '{
      act: $act,
      skip_reason: (if $skip_reason == "" then null else $skip_reason end),
      artifact_id: (if $artifact_id == "" then null else $artifact_id end),
      artifact_source: (if $artifact_source == "" then null else $artifact_source end),
      incremental_count: $incremental_count,
      max_incremental: $max_incremental,
      body_path: (if $body_path == "" then null else $body_path end),
      artifact_ts: (if $artifact_ts == "" then null else $artifact_ts end)
    }'
}

if [ -z "$latest" ]; then
  emit false "no gate-authored OpenCode review found" "" "" 0 "" ""
  exit 0
fi

latest_id="$(printf '%s' "$latest" | jq -r '.id')"
latest_source="$(printf '%s' "$latest" | jq -r '.source')"
latest_ts="$(printf '%s' "$latest" | jq -r '.ts // empty')"
is_skip="$(printf '%s' "$latest" | jq -r '.is_skip_incremental')"

# Count incremental-cycle artifacts (actionable INCREMENTAL reports plus
# skip-incremental comments) since the latest FULL review, walking the unified
# descending timeline. Stop at the first FULL.
count_incrementals() {
  printf '%s' "$artifacts" | jq -r '
    reduce .[] as $a ({count: 0, stop: false};
      if .stop then .
      elif ($a.is_actionable and ($a.body | test("\\*\\*Review Type:\\*\\*[[:space:]]*FULL"))) then .stop = true
      elif ($a.is_actionable and ($a.body | test("\\*\\*Review Type:\\*\\*[[:space:]]*INCREMENTAL"))) then .count += 1
      elif $a.is_skip_incremental then .count += 1
      else .
      end
    ) | .count
  '
}

incremental_count="$(count_incrementals)"

if [ "$is_skip" = "true" ]; then
  emit false "latest gate artifact is a skip-incremental comment" "$latest_id" "$latest_source" "$incremental_count" "" "$latest_ts"
  exit 0
fi

if [ "$incremental_count" -gt "$max_incremental" ]; then
  emit false "incremental cycle cap exceeded" "$latest_id" "$latest_source" "$incremental_count" "" "$latest_ts"
  exit 0
fi

latest_body="$(printf '%s' "$latest" | jq -r '.body')"
if [ -n "$body_out_path" ]; then
  mkdir -p "$(dirname "$body_out_path")"
  printf '%s\n' "$latest_body" > "$body_out_path"
fi

emit true "" "$latest_id" "$latest_source" "$incremental_count" "$body_out_path" "$latest_ts"
