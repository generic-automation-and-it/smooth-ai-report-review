#!/usr/bin/env bash
# review-decisions.sh — `/ai-review --usedecisions`: decision-model FIX/SKIP
# recommendations for the numbered findings of an OpenCode Review Report
# (LADR-097, in ai-review-report's AGENTS.md).
#
# Usage: review-decisions.sh <pr> [review-body-file]
#   review-body-file  the review body the agent already fetched in analyse
#                     step 3. Omitted → the latest github-actions[bot] review
#                     or comment on <pr> that carries `## 🔍 Issues Summary`.
#
# Uses the SAME environment as the CI gate's decision step — nothing new to
# configure: OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER / _MODEL /
# _MIN_PROBABILITY / _TIMEOUT, and that provider's existing key
# (OPENCODE-GO-DECISIONS → OPENCODE_GO_OPENAI_API_KEY, OPENROUTER-DECISIONS →
# OPENCODE_OPENROUTER_API_KEY). OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS is NOT
# required: passing --usedecisions is the opt-in.
#
# The judge gets what a human checks a finding against: the PR diff hunk
# (`gh pr diff`), the PR description's Skip Areas bullets, and — when the
# review carries the gate's invisible run marker and the run artifact is still
# downloadable — the finding's quoted evidence (LADR-062).
#
# Prints the recommendation table on stdout and the path of the scored JSON.
# Always exits 0 unless the arguments are wrong (64): recommendations are
# advisory, and their absence must never stop an analyse run.
#
# The scorer lives in the ai-review-report skill (its sibling folder in every
# install shape: in-repo, copy-install, the Claude Code plugin whose source is
# the whole repo, and the npm plugin's .agents/skills links). Set
# AI_REVIEW_REPORT_DIR to point elsewhere.
set -uo pipefail

pr="${1:-}"
body_file="${2:-}"
case "$pr" in
  ''|*[!0-9]*) echo "usage: review-decisions.sh <pr-number> [review-body-file]" >&2; exit 64 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${AI_REVIEW_REPORT_DIR:-$SCRIPT_DIR/../../ai-review-report}"
LIB="$REPORT_DIR/scripts/lib"
if [ ! -f "$LIB/recommend-fix-skip.sh" ]; then
  echo "⚠️  --usedecisions needs the ai-review-report skill's decision scorer (scripts/lib/recommend-fix-skip.sh), which is not installed next to ai-review (looked in ${REPORT_DIR}). Install the smooth-ai-review-report plugin or set AI_REVIEW_REPORT_DIR. Continuing without decision-model recommendations."
  exit 0
fi
for tool in gh jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "⚠️  --usedecisions needs ${tool} — continuing without decision-model recommendations."
    exit 0
  fi
done

work="$(mktemp -d "${TMPDIR:-/tmp}/ai-review-decisions-${pr}.XXXXXX")"

# --- Review body ---------------------------------------------------------------------
if [ -n "$body_file" ]; then
  if [ ! -s "$body_file" ]; then
    echo "⚠️  review body file '${body_file}' is missing or empty — continuing without decision-model recommendations."
    exit 0
  fi
  cp "$body_file" "$work/review.md"
else
  # Same timeline the ai-analyse guard reads: reviews and issue comments by the
  # gate's bot, newest first, first one carrying the Issues Summary.
  {
    gh api --paginate "repos/{owner}/{repo}/pulls/${pr}/reviews" 2>/dev/null \
      | jq -c '.[] | {ts: .submitted_at, author: .user.login, body: .body}'
    gh api --paginate "repos/{owner}/{repo}/issues/${pr}/comments" 2>/dev/null \
      | jq -c '.[] | {ts: .created_at, author: .user.login, body: .body}'
  } | jq -rs '
      map(select(.author == "github-actions[bot]" and ((.body // "") | test("(^|\n)## 🔍 Issues Summary"))))
      | sort_by(.ts) | last | .body // empty' > "$work/review.md"
  if [ ! -s "$work/review.md" ]; then
    echo "⚠️  no OpenCode Review Report with an Issues Summary found on PR ${pr} — continuing without decision-model recommendations."
    exit 0
  fi
fi

# --- Judge context -------------------------------------------------------------------
if ! gh pr diff "$pr" > "$work/pr_diff.txt" 2>"$work/pr_diff.err"; then
  echo "⚠️  gh pr diff ${pr} failed ($(head -n 1 "$work/pr_diff.err" | head -c 160)) — findings are judged without their diff hunks."
  : > "$work/pr_diff.txt"
fi
gh pr view "$pr" --json body -q .body 2>/dev/null \
  | bash "$LIB/extract-review-notes.sh" --skip-areas > "$work/skip_areas.md" 2>/dev/null || : > "$work/skip_areas.md"

artifact=""
run_id="$(sed -n 's/.*<!-- ai-review-report run=\([0-9][0-9]*\) -->.*/\1/p' "$work/review.md" | tail -n 1)"
if [ -n "$run_id" ]; then
  if gh run download "$run_id" -n "review-run-${run_id}" -D "$work/artifact" >/dev/null 2>&1 \
     && [ -s "$work/artifact/findings.merged.json" ]; then
    artifact="$work/artifact/findings.merged.json"
  else
    echo "ℹ️  run artifact review-run-${run_id} is not downloadable (expired or no access) — findings are judged without their quoted evidence."
  fi
fi

bash "$LIB/recommend-fix-skip.sh" --scope review \
  --review "$work/review.md" --out-dir "$work/out" \
  --diff "$work/pr_diff.txt" --skip-areas "$work/skip_areas.md" \
  ${artifact:+--artifact "$artifact"}
if [ -s "$work/out/decisions.json" ]; then
  echo ""
  echo "Scored findings: $work/out/decisions.json"
fi
exit 0
