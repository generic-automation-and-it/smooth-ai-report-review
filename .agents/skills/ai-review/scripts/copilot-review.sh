#!/usr/bin/env bash
# ai-review — deterministic GitHub plumbing for processing a Copilot PR review.
#
# The agent keeps all *judgment* (parsing the review, fix/skip decisions, and the
# text of every reply/summary). This script only performs the fixed GitHub calls so
# the raw REST/GraphQL never has to live in skill prose. Reply/summary bodies are
# read from STDIN to avoid quoting/newline breakage.
#
# Subcommands:
#   detect <pr>                 Print COPILOT if the PR's review or review comments are
#                               authored by the Copilot reviewer bot, else OTHER.
#   threads <pr>                Print the PR's review threads as JSON: each node has
#                               { id, isResolved, comments:[{ databaseId, path, author, body }] }.
#                               The agent maps each parsed issue to a comment databaseId + thread id.
#   reply <pr> <comment-id>     Reply to inline review <comment-id> on <pr>; body read from STDIN.
#   resolve <thread-id>         Mark review thread <thread-id> resolved (GraphQL resolveReviewThread).
#   summary <pr>                Post a PR-level comment (the fix/skip summary table); body from STDIN.
#
# Repo is auto-detected by gh from the current directory ({owner}/{repo} placeholders).
# Usage examples:
#   .../copilot-review.sh detect 48
#   .../copilot-review.sh threads 48
#   echo "**ai-review: FIX** — handled in <sha>" | .../copilot-review.sh reply 48 2101234567
#   .../copilot-review.sh resolve PRRT_kwDOABC123
#   cat summary.md | .../copilot-review.sh summary 48
set -euo pipefail

COPILOT_LOGINS_RE='^(Copilot|copilot|copilot\[bot\]|copilot-pull-request-reviewer\[bot\])$'

repo_owner() { gh repo view --json owner -q .owner.login; }
repo_name()  { gh repo view --json name  -q .name; }

cmd_detect() {
  local pr="$1"
  # Check both the formal reviews and the inline review comments for a Copilot-bot author.
  local hit
  hit=$(
    {
      gh api --paginate "repos/{owner}/{repo}/pulls/${pr}/reviews" -q '.[].user.login'
      gh api --paginate "repos/{owner}/{repo}/pulls/${pr}/comments" -q '.[].user.login'
    } 2>/dev/null | grep -Ei "$COPILOT_LOGINS_RE" | head -n1 || true
  )
  if [ -n "$hit" ]; then echo "COPILOT"; else echo "OTHER"; fi
}

cmd_threads() {
  local pr="$1"
  gh api graphql \
    -f owner="$(repo_owner)" -f repo="$(repo_name)" -F pr="$pr" \
    -f query='
      query($owner:String!,$repo:String!,$pr:Int!){
        repository(owner:$owner,name:$repo){
          pullRequest(number:$pr){
            reviewThreads(first:100){
              nodes{
                id isResolved
                comments(first:50){ nodes{ databaseId path author{ login } body } }
              }
            }
          }
        }
      }' \
    -q '.data.repository.pullRequest.reviewThreads.nodes'
}

cmd_reply() {
  local pr="$1" comment_id="$2"
  gh api -X POST "repos/{owner}/{repo}/pulls/${pr}/comments/${comment_id}/replies" \
    -F body=@- >/dev/null
  echo "REPLIED ${comment_id}"
}

cmd_resolve() {
  local thread_id="$1"
  gh api graphql \
    -f query='mutation($threadId:ID!){ resolveReviewThread(input:{threadId:$threadId}){ thread{ isResolved } } }' \
    -f threadId="$thread_id" \
    -q '.data.resolveReviewThread.thread.isResolved' >/dev/null
  echo "RESOLVED ${thread_id}"
}

cmd_summary() {
  local pr="$1"
  gh api -X POST "repos/{owner}/{repo}/issues/${pr}/comments" \
    -F body=@- -q '.html_url'
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    detect)  cmd_detect  "$@" ;;
    threads) cmd_threads "$@" ;;
    reply)   cmd_reply   "$@" ;;
    resolve) cmd_resolve "$@" ;;
    summary) cmd_summary "$@" ;;
    *) echo "usage: copilot-review.sh {detect|threads|reply|resolve|summary} ..." >&2; exit 2 ;;
  esac
}

main "$@"
