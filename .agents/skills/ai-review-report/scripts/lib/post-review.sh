#!/bin/bash
# post-review.sh — post a PR review anchored to the commit it reviewed.
#
# SOURCED, not executed (same convention as gh-retry.sh, resolve-diff-base.sh).
#
# `gh pr review` always targets the PR's current head. A review produced for an
# older commit was attached to whatever the head was at post time (PR #91 review
# 5860640019: body `ddb2d36`, API `commit_id` `2d05106`), so the posted verdict
# named a commit the review never saw. The REST call below pins `commit_id` to
# the reviewed SHA, keeping the body and the anchor in agreement.
#
# Usage:
#   post_review <owner/repo> <pr> <commit-sha> <event> <body-file>
#     event: APPROVE | REQUEST_CHANGES | COMMENT
post_review() {
  local repo="$1" pr="$2" commit="$3" event="$4" body_file="$5"
  gh api --method POST \
    "repos/${repo}/pulls/${pr}/reviews" \
    -f "commit_id=${commit}" \
    -f "event=${event}" \
    -F "body=@${body_file}"
}
