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
# The judge gets what a human checks a finding against: the PR diff hunk AS OF
# THE REVIEWED COMMIT (lib/review-diff.sh — never the code pushed after the
# review), the PR description's Skip Areas bullets, the code around each
# finding at that commit when it is in the local clone, and — when the review
# names its run and the run artifact is still downloadable (LADR-062) — the
# finding's quoted evidence and the chunk rules the gate used. When the gate
# already answered fix_skip against the same Skip Areas, that answer is reused
# rather than re-asked (LADR-098).
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

# --- The run artifact (LADR-062) ---------------------------------------------------
# Named by the review's invisible marker: `run-id=` is always written since
# LADR-098, `run=` only when the gate scored (older reviews carry only that).
artifact=""
reviewed_sha=""
run_id="$(sed -n 's/.*<!-- ai-review-report run\(-id\)\{0,1\}=\([0-9][0-9]*\) -->.*/\2/p' "$work/review.md" | tail -n 1)"
if [ -n "$run_id" ]; then
  if gh run download "$run_id" -n "review-run-${run_id}" -D "$work/artifact" >/dev/null 2>&1 \
     && [ -s "$work/artifact/findings.merged.json" ]; then
    artifact="$work/artifact/findings.merged.json"
    reviewed_sha="$(jq -r '.head_sha // "" | select(test("^[0-9a-f]{7,40}$"))' "$work/artifact/metadata.json" 2>/dev/null || true)"
  else
    echo "ℹ️  run artifact review-run-${run_id} is not downloadable (expired or no access) — findings are judged without their quoted evidence and every one is re-scored."
  fi
fi

# --- Judge context -------------------------------------------------------------------
# The diff AS REVIEWED: judging an older review against code pushed after it
# scores the wrong lines (LADR-098). review-diff.sh compares the reviewed
# commit (artifact metadata, else the review header) with the PR head.
# ai-review and ai-review-report ship as separate plugins, so the report skill
# found next to this one can predate review-diff.sh (and --rev): then fall back
# to the current diff and say that the revision was not checked.
if [ -f "$LIB/review-diff.sh" ]; then
  diff_state="$(bash "$LIB/review-diff.sh" "$pr" "$work/review.md" "$work/pr_diff.txt" "$reviewed_sha")"
  diff_revision="$(printf '%s\n' "$diff_state" | sed -n 1p)"
  reviewed_sha="$(printf '%s\n' "$diff_state" | sed -n 2p)"
else
  gh pr diff "$pr" > "$work/pr_diff.txt" 2>/dev/null || : > "$work/pr_diff.txt"
  diff_revision="unknown"
  reviewed_sha=""
  echo "ℹ️  the installed ai-review-report skill predates review-diff.sh (LADR-098) — update it to judge findings at the reviewed commit."
fi
case "$diff_revision" in
  current) ;;
  reviewed) echo "ℹ️  PR ${pr} moved on since this review — findings are judged against the reviewed commit ${reviewed_sha:0:7}, not the current head." ;;
  unknown) echo "⚠️  could not tell which commit this review judged — findings are judged against the CURRENT PR diff, which may differ from what was reviewed." ;;
  *)
    echo "⚠️  the diff at the reviewed commit ${reviewed_sha:0:7} could not be established for PR ${pr} (it moved on and the compare failed, or its head could not be read) — no decision-model recommendations (judging the current code would score lines the review never saw)."
    exit 0 ;;
esac
[ -s "$work/pr_diff.txt" ] || echo "⚠️  no PR diff available — findings are judged without their diff hunks."
if gh pr view "$pr" --json body -q .body > "$work/pr_body.md" 2>/dev/null && \
   bash "$LIB/extract-review-notes.sh" --skip-areas < "$work/pr_body.md" > "$work/skip_areas.md" 2>/dev/null; then
  : # A successful read may legitimately have no Skip Areas.
else
  rm -f "$work/skip_areas.md"
  echo "⚠️  could not verify the PR's current Skip Areas — gate predictions will be re-scored."
fi

bash "$LIB/recommend-fix-skip.sh" --scope review \
  --review "$work/review.md" --out-dir "$work/out" \
  --diff "$work/pr_diff.txt" --skip-areas "$work/skip_areas.md" \
  ${artifact:+--artifact "$artifact"} ${reviewed_sha:+--rev "$reviewed_sha"}
if [ -s "$work/out/decisions.json" ]; then
  echo ""
  echo "Scored findings: $work/out/decisions.json"
fi
exit 0
