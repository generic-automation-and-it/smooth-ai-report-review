#!/bin/bash
# review-diff.sh — the PR diff AS OF THE REVIEWED COMMIT, for judging a posted
# review's findings after the fact (LADR-098).
#
# Usage: review-diff.sh <pr> <review_body> <out_diff> [reviewed_sha]
#   review_body   the posted gate review; its header names the commit it
#                 reviewed (`## 🤖 OpenCode CLI Code Review - Commit: `abc1234``)
#   reviewed_sha  OPTIONAL, preferred over the header: the full head_sha from
#                 the run artifact's metadata.json
#
# Prints one word on stdout, the revision the diff in <out_diff> describes:
#   current      the reviewed commit IS the PR head → `gh pr diff`
#   reviewed     the PR moved on since the review → the diff between the base
#                branch and the reviewed commit (compare API), so a finding is
#                judged against the code it was raised on, not code written
#                after it
#   unknown      no reviewed commit could be determined → `gh pr diff`, and the
#                caller should say that the revision was not verified
#   unavailable  the reviewed commit is known but the diff at it cannot be
#                established — the PR moved on and the compare failed, OR the
#                PR head itself could not be read, so nobody can tell whether
#                it moved on → <out_diff> is empty; the caller must NOT score
#                against the current diff instead (that is the defect this
#                script exists to prevent)
# and the full reviewed sha on the second line when one is known (empty
# otherwise), so the caller can read source at that revision.
#
# Always exits 0 (64 on usage). Needs gh (authenticated) and jq; repo from the
# current checkout or GH_REPO.
set -uo pipefail

pr="${1:-}"
body="${2:-}"
out="${3:-}"
known="${4:-}"
case "$pr" in ''|*[!0-9]*) echo "usage: review-diff.sh <pr> <review_body> <out_diff> [reviewed_sha]" >&2; exit 64 ;; esac
[ -n "$out" ] || { echo "usage: review-diff.sh <pr> <review_body> <out_diff> [reviewed_sha]" >&2; exit 64; }
: > "$out"

reviewed="$(printf '%s' "$known" | tr -cd '0-9a-f')"
if [ -z "$reviewed" ] && [ -n "$body" ] && [ -f "$body" ]; then
  reviewed="$(sed -n 's/^## .*Code Review.* Commit: `\([0-9a-f]\{7,40\}\)`.*/\1/p' "$body" | head -n 1)"
fi

pr_json="$(gh pr view "$pr" --json headRefOid,baseRefName 2>/dev/null || echo '{}')"
head="$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null)"
base="$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""' 2>/dev/null)"

current_diff() { gh pr diff "$pr" > "$out" 2>/dev/null || : > "$out"; }

# No reviewed commit: nothing to pin to, so the current diff is the only
# option — and the caller says the revision was not verified.
if [ -z "$reviewed" ]; then
  current_diff
  printf 'unknown\n\n'
  exit 0
fi
# A known reviewed commit but an unreadable PR head: the PR may have moved on,
# and falling back to the current diff would score code the review never saw
# (review of PR 179, finding 1). Refuse instead.
if [ -z "$head" ]; then
  printf 'unavailable\n%s\n' "$reviewed"
  exit 0
fi
# The header carries an abbreviated sha; the PR head is always full.
case "$head" in
  "$reviewed"*) current_diff; printf 'current\n%s\n' "$head"; exit 0 ;;
esac

# The compare API resolves an abbreviated sha, and three-dot semantics diff
# the reviewed commit against its merge base with the base branch — the same
# range the gate reviewed.
full="$(gh api "repos/{owner}/{repo}/commits/${reviewed}" --jq '.sha' 2>/dev/null || true)"
if [ -n "$base" ] && [ -n "$full" ] \
   && gh api -H 'Accept: application/vnd.github.v3.diff' \
        "repos/{owner}/{repo}/compare/${base}...${full}" > "$out" 2>/dev/null \
   && [ -s "$out" ]; then
  printf 'reviewed\n%s\n' "$full"
else
  : > "$out"
  printf 'unavailable\n%s\n' "$full"
fi
exit 0
