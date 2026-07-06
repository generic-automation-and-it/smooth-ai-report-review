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

minimize_previous_reviews() {
  local reviews_json
  local review_node_ids
  local review_count
  local node_id

  # Get all reviews for the PR via GraphQL (filtered below by review-body marker, not author)
  reviews_json=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr_number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr_number) {
          reviews(first: 100) {
            nodes {
              id
              databaseId
              body
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

  # Extract review Node IDs for AI reviews, excluding the current one
  review_node_ids=$(echo "$reviews_json" | jq -r \
    --arg current_id "$CURRENT_REVIEW_ID" \
    '.data.repository.pullRequest.reviews.nodes[]? |
     select(.body | test("^#+ 🤖 (Gemini CLI|OpenCode CLI) Code Review")) |
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

  while IFS= read -r node_id; do
    if [ -z "$node_id" ]; then
      continue
    fi

    if minimize_node "$node_id" "review"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Small delay to avoid rate limiting
    sleep 0.5
  done <<< "$review_node_ids"
  echo ""
}

minimize_previous_analyse_comments() {
  local comments_json
  local comment_node_ids
  local comment_count
  local node_id

  # These body markers are owned by .github/workflows/pipeline-ai-analyse.yml;
  # keep the regex in sync with its posted summary and limit-exceeded comments.
  comments_json=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr_number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr_number) {
          comments(first: 100) {
            nodes {
              id
              body
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

  comment_node_ids=$(echo "$comments_json" | jq -r \
    '.data.repository.pullRequest.comments.nodes[]? |
     select(.body | test("^#+ ai-analyse auto-fix (summary|limit exceeded)")) |
     .id'
  )

  if [ -z "$comment_node_ids" ]; then
    echo "✅ No previous ai-analyse auto-fix comments found to minimize"
    echo ""
    return 0
  fi

  comment_count=$(echo "$comment_node_ids" | wc -l | tr -d ' ')
  echo "Found ${comment_count} previous ai-analyse auto-fix comment(s) to minimize"
  echo ""

  while IFS= read -r node_id; do
    if [ -z "$node_id" ]; then
      continue
    fi

    if minimize_node "$node_id" "ai-analyse comment"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Small delay to avoid rate limiting
    sleep 0.5
  done <<< "$comment_node_ids"
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
