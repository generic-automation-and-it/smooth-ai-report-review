#!/bin/bash
# shellcheck disable=SC2016
set -e

# Script: minimize-previous-reviews.sh
# Purpose: Minimize (hide) previous AI reviews and ai-analyse summaries when a new full review is posted
# Usage: Called from pipeline-code-review-report.yml workflow after posting a full review
# Arguments: $1=PR_NUMBER $2=REVIEW_TYPE $3=GITHUB_REPOSITORY $4=CURRENT_REVIEW_ID (optional)

PR_NUMBER="$1"
REVIEW_TYPE="$2"
GITHUB_REPOSITORY="$3"
CURRENT_REVIEW_ID="${4:-}"

if [ -z "$PR_NUMBER" ] || [ -z "$REVIEW_TYPE" ] || [ -z "$GITHUB_REPOSITORY" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: minimize-previous-reviews.sh PR_NUMBER REVIEW_TYPE GITHUB_REPOSITORY [CURRENT_REVIEW_ID]"
  exit 1
fi

if [ "$REVIEW_TYPE" != "full" ]; then
  echo "Review type is '$REVIEW_TYPE' - skipping minimization (only full reviews trigger this)"
  exit 0
fi

echo "=========================================="
echo "Minimizing Previous AI Reviews and Analyse Summaries"
echo "=========================================="
echo "PR: #${PR_NUMBER}"
echo "Review Type: ${REVIEW_TYPE}"
echo ""

# Extract repository owner and name
REPO_OWNER=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)
REPO_NAME=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f2)

SUCCESS_COUNT=0
FAIL_COUNT=0

minimize_node() {
  local node_id="$1"
  local label="$2"
  local mutation_result
  local is_minimized

  echo "Minimizing ${label} ${node_id}..."

  mutation_result=$(gh api graphql -f query='
    mutation($subjectId: ID!, $classifier: ReportedContentClassifiers!) {
      minimizeComment(input: {subjectId: $subjectId, classifier: $classifier}) {
        minimizedComment {
          isMinimized
          minimizedReason
        }
      }
    }' \
    -f subjectId="${node_id}" \
    -f classifier="OUTDATED" 2>&1) || {
    echo "  ❌ Failed to minimize ${label} ${node_id}"
    echo "  Error: $mutation_result"
    return 1
  }

  # Check if mutation was successful
  is_minimized=$(echo "$mutation_result" | jq -r '.data.minimizeComment.minimizedComment.isMinimized' 2>/dev/null || echo "false")

  if [ "$is_minimized" = "true" ]; then
    echo "  ✅ Successfully minimized ${label} ${node_id}"
    return 0
  fi

  echo "  ⚠️ Minimize mutation returned but status unclear for ${node_id}"
  echo "  Response: $mutation_result"
  return 1
}

# Minimize a newline-separated list of node IDs with bounded parallelism.
# Sequential one-mutation-plus-0.5s-sleep loops cost ~1s per node — 15 stale
# reviews/comments took ~16s on run 30817404772, and the list grows with PR
# age. Four concurrent mutations keep well under GitHub's secondary rate
# limits while collapsing that to ~2-3s. Each minimize_node runs in a
# subshell, so tallies go through files, not shell variables.
minimize_ids_parallel() {
  local label="$1" node_ids="$2"
  local results_dir node_id idx=0
  local pids=()
  results_dir="$(mktemp -d)"

  while IFS= read -r node_id; do
    [ -z "$node_id" ] && continue
    (
      if minimize_node "$node_id" "$label"; then
        : > "${results_dir}/ok_${idx}"
      else
        : > "${results_dir}/fail_${idx}"
      fi
    ) &
    pids+=($!)
    idx=$((idx + 1))
    # Rolling window of 4: wait on the oldest before launching a fifth.
    # (`wait -n` is avoided — local runs may be on macOS bash 3.2.)
    if [ "${#pids[@]}" -ge 4 ]; then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
    fi
  done <<< "$node_ids"

  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  SUCCESS_COUNT=$((SUCCESS_COUNT + $(find "$results_dir" -name 'ok_*' | wc -l | tr -d ' ')))
  FAIL_COUNT=$((FAIL_COUNT + $(find "$results_dir" -name 'fail_*' | wc -l | tr -d ' ')))
  rm -rf "$results_dir"
}

minimize_previous_reviews() {
  local reviews_json
  local review_node_ids
  local review_count
  local node_id

  # Get the PR's reviews via GraphQL, filtered below by review-body marker plus
  # the same two guards the issue-comment branch uses. `PullRequestReview`
  # implements `Minimizable` (verified against the live schema — the interface's
  # possibleTypes are CommitComment, DiscussionComment, GistComment, IssueComment,
  # PullRequestReview, PullRequestReviewComment), so `isMinimized` and
  # `viewerDidAuthor` are both available here and mean what they mean there.
  #
  # `last: 100` for the same reason as the comments query: the query is
  # unpaginated and GitHub returns reviews oldest-first, so on a long-lived PR
  # `first` would keep re-reading the window whose gate reviews are already hidden
  # and never reach the ones still visible.
  reviews_json=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr_number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr_number) {
          reviews(last: 100) {
            nodes {
              id
              databaseId
              body
              isMinimized
              viewerDidAuthor
            }
          }
        }
      }
    }' \
    -f owner="${REPO_OWNER}" \
    -f repo="${REPO_NAME}" \
    -F pr_number="$PR_NUMBER" 2>&1) || {
    echo "⚠️ Failed to fetch PR reviews via GraphQL — skipping minimization (non-fatal)."
    echo "$reviews_json"
    return 0
  }

  # Extract review Node IDs for AI reviews, excluding the current one.
  # `.isMinimized != true` keeps a long-lived PR from re-minimizing its whole
  # review history on every run (and from reporting an invented "Minimized: N");
  # `!= true` rather than `== false` so a null field degrades to "minimize it".
  # `.viewerDidAuthor` keeps a human review that opens with the gate header — a
  # reviewer quoting it unquoted at the top of their own review is enough — from
  # being hidden, and is keyed on the authenticated identity rather than a
  # hardcoded `github-actions[bot]` so it holds under a PAT or GitHub App.
  review_node_ids=$(echo "$reviews_json" | jq -r \
    --arg current_id "$CURRENT_REVIEW_ID" \
    '.data.repository.pullRequest.reviews.nodes[]? |
     select(.body | test("^#+ 🤖 (Gemini CLI|OpenCode CLI) Code Review")) |
     select(.isMinimized != true) |
     select(.viewerDidAuthor == true) |
     select(if $current_id != "" then (.databaseId | tostring) != $current_id else true end) |
     .id'
  )

  if [ -z "$review_node_ids" ]; then
    echo "✅ No previous AI reviews found to minimize"
    echo ""
    return 0
  fi

  review_count=$(echo "$review_node_ids" | wc -l | tr -d ' ')
  echo "Found ${review_count} previous AI review(s) to minimize"
  echo ""

  minimize_ids_parallel "review" "$review_node_ids"
  echo ""
}

minimize_previous_analyse_comments() {
  local comments_json
  local comment_node_ids
  local comment_count
  local node_id

  # These body markers are owned by .github/workflows/pipeline-ai-analyse.yml;
  # keep the regex in sync with its posted summary and limit-exceeded comments.
  #
  # `last: 100`, not `first: 100`: this query is unpaginated, and GitHub returns
  # issue comments oldest-first. On a PR that has accumulated more than 100
  # comments, `first` fetches the oldest window — the one whose gate comments were
  # already minimized by earlier runs — so the visible clutter at the bottom of
  # the PR would never be reached. `last` fetches the newest window, which is
  # exactly where the comments a reader still sees live.
  comments_json=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr_number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr_number) {
          comments(last: 100) {
            nodes {
              id
              body
              isMinimized
              viewerDidAuthor
            }
          }
        }
      }
    }' \
    -f owner="${REPO_OWNER}" \
    -f repo="${REPO_NAME}" \
    -F pr_number="$PR_NUMBER" 2>&1) || {
    echo "⚠️ Failed to fetch PR comments via GraphQL — skipping ai-analyse comment minimization (non-fatal)."
    echo "$comments_json"
    return 0
  }

  # A full review supersedes every prior comment this pipeline leaves on the
  # PR, so anything the AI-review-report gate or skill authored as an issue
  # comment is minimized. Three header families cover all of it:
  #   - the gate header "## 🤖 OpenCode CLI Code Review" — the main summary's
  #     mirror and every skip notice (LADR-059 trivial-skip, run-review.sh
  #     Step 16 blocked-incremental), all posted with `gh pr comment`
  #   - the failure header "## ❌ OpenCode CLI Code Review Workflow Failed" —
  #     the workflow's `Post Error Comment` step
  # Formal reviews are minimized separately (minimize_previous_reviews),
  # including the AGENTS.md-validation BLOCKED review, because those are
  # `gh pr review` subjects, not issue comments — this comment query never
  # sees them.
  #
  # Matching on the leading header (anchored at `^`) instead of enumerating
  # per-shape markers means a future gate comment shape is covered without a
  # fresh audit, and a quoted copy inside someone else's comment never matches.
  # The ai-analyse summaries are out of scope for this rule's intent but keep
  # their own branch so the analyse workflow's postings stay handled; the two
  # header families above cannot collide with them (`# ai-analyse`, no gate
  # header). It is safe to minimize these classes: ai-analyse reads the REST
  # timeline and never looks at isMinimized, so its incremental cap count is
  # unaffected either way.
  #
  # Two guards keep the widened match from doing damage a per-shape match could
  # not:
  #   - `.isMinimized != true` — the old selector matched at most the one or two
  #     trivial-skip notices, so re-minimizing them was free. A header match sees
  #     EVERY gate comment the PR ever accumulated, so without this every full
  #     review would re-fire `minimizeComment` for the whole history and report
  #     an invented "Minimized: N". `!= true` (not `== false`) so a null/absent
  #     field degrades to "minimize it", never to "skip everything".
  #   - `.viewerDidAuthor` on the two gate headers — matching on body alone would
  #     hide a *human's* comment that opens with the gate header (pasting it
  #     unquoted while discussing a review is enough). Keyed on the authenticated
  #     identity rather than a hardcoded `github-actions[bot]` so the guard holds
  #     for consumers whose gate posts under a PAT or a GitHub App. The
  #     ai-analyse branch is deliberately left author-agnostic: it is posted by a
  #     different workflow and its behaviour here is unchanged by design.
  comment_node_ids=$(echo "$comments_json" | jq -r \
    '.data.repository.pullRequest.comments.nodes[]? |
     select(.isMinimized != true) |
     select(
       (.body | test("^#+ ai-analyse auto-fix (summary|limit exceeded)"))
       or (
         (.viewerDidAuthor == true)
         and (
           (.body | test("^#+ 🤖 (Gemini CLI|OpenCode CLI) Code Review"))
           or (.body | test("^#+ ❌ OpenCode CLI Code Review Workflow Failed"))
         )
       )
     ) |
     .id'
  )

  if [ -z "$comment_node_ids" ]; then
    echo "✅ No previous gate / ai-analyse issue comments left to minimize"
    echo ""
    return 0
  fi

  comment_count=$(echo "$comment_node_ids" | wc -l | tr -d ' ')
  echo "Found ${comment_count} previous gate / ai-analyse issue comment(s) to minimize"
  echo ""

  minimize_ids_parallel "issue comment" "$comment_node_ids"
  echo ""
}

minimize_previous_reviews
minimize_previous_analyse_comments

echo ""
echo "=========================================="
echo "Minimization Complete"
echo "=========================================="
echo "✅ Minimized: ${SUCCESS_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "⚠️ Failed: ${FAIL_COUNT}"
fi
echo ""

# Exit successfully even if some failed
exit 0
