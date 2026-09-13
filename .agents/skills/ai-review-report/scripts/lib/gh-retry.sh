#!/bin/bash
# gh-retry.sh — one bounded retry for a transient GitHub failure (LADR-078).
#
# SOURCED, not executed: it wraps calls inline in the caller's shell, so it
# follows the `source` convention used by parse-review-comment-options.sh,
# resolve-diff-base.sh and check-versions.sh rather than the `bash <path>`
# convention used by install-opencode.sh and friends.
#
# The problem it solves: run-review.sh runs under `set -euo pipefail`, so a
# single transient 5xx from GitHub aborted the whole run. On 2026-09-13 that
# discarded three reviews that had already been generated in full — the model
# work was done, the verdict computed, and one unretried mutation threw it away.
#
# Deliberately NOT a general resilience layer:
#   - ONE retry, then fail exactly as before. No exponential backoff.
#   - A fixed delay, not a ramp.
#   - A retry ALLOWLIST, not a 4xx denylist: an unrecognised error is not
#     retried, so behaviour is byte-identical to pre-LADR-078 for every failure
#     mode we have not explicitly classified as transient. This can never make
#     a `422 body too large` or a `403` permission error worse.
#
# Usage:
#   gh_retry -- gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr}"
#   gh_retry --verify gh_count_gate_reviews "${pr}" -- gh pr review "${pr}" --approve --body-file body.md
#
# Everything after `--` is the command and its arguments, executed directly
# (no `eval`, no re-quoting). stdout passes through untouched so `$( )` capture
# at read sites keeps working; stderr is captured for classification and then
# replayed to stderr.

# Fixed delay, in seconds. This is a CONSTANT, not operator configuration:
# it is deliberately NOT wired to any workflow `env:` block or GitHub Variable.
# The override exists solely so test-gh-retry.sh does not sleep 30s per case.
GH_RETRY_DELAY_SECONDS="${GH_RETRY_DELAY_SECONDS:-30}"

# Kill switch. Unlike build-code-graph.sh / install-rtk.sh — where the CALLER
# decides whether to invoke the lib at all — this lib reads its own toggle,
# because the `gh` call must always happen; only the retry is optional.
# Truthiness uses the dominant `tr -cs` tokenizing idiom (run-review.sh:1029,
# :545) so pathological values align with the workflow's
# `contains('1 true yes on', …)` step conditions.
#
# Lowercasing goes through `tr`, not `${v,,}`, on purpose: run-review.sh guards
# for Bash >= 4 but local-review.sh does not, and macOS still ships Bash 3.2
# where `${v,,}` is a hard "bad substitution". That failure was silent in the
# worst way — the expansion error made this function return non-zero, which
# reads as "retry disabled", so the whole feature would have been dead on every
# macOS local run while the tests still looked plausible.
_gh_retry_enabled() {
  local v lowered
  v="${OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY:-1}"
  lowered="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$lowered" | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'
}

# The retry allowlist. Reads the captured stderr on stdin.
#
# Anchored on HTTP-status *phrasing* rather than bare numerics: a bare `500`
# would match the `per_page=500` in the review-history read's own URL if gh
# echoed it back, and spuriously retry a genuine 404.
#
# The first three alternatives are the exact signatures observed on 2026-09-13:
#   failed to create review: non-200 OK status code: 502 Bad Gateway
#   failed to create review: GraphQL: Something went wrong while executing your query
_gh_retry_is_transient() {
  grep -qiE \
    'non-200 OK status code: 5|status code: 5|HTTP 5[0-9][0-9]|bad gateway|something went wrong while executing your query|service unavailable|gateway time-?out|internal server error|server error|timed out|timeout|connection reset|connection refused|broken pipe|unexpected EOF|TLS handshake|no such host|temporary failure in name resolution|temporarily unavailable'
}

# --- Verifiers ---------------------------------------------------------------
#
# A 5xx does not tell us whether the mutation committed — GitHub may have
# applied it and lost the response. A blind retry would then post a second
# review. So each write site passes a COUNTER function; gh_retry snapshots the
# count before attempt 1 and re-reads it after the failure. Count increased =>
# the call landed => do not re-post.
#
# A count delta is used rather than a `submitted_at >= $since` timestamp window
# on purpose: a delta has no spurious-"landed" mode. A timestamp window can
# report landed when it did not (clock skew, or an unrelated gate review inside
# the margin), and THAT is the dangerous direction — it would skip the retry and
# lose the review silently. A spurious "not landed" merely retries.
#
# Both counters return non-zero when their own read fails, which gh_retry treats
# as "cannot verify" and proceeds to retry. Same reasoning: a duplicate review
# is visible, cosmetic, and self-healing (minimize-previous-reviews.sh collapses
# prior gate reviews on the next run); a silently-missing review is neither.
#
# The match shape is lifted from the existing, proven filter at
# run-review.sh:766-773 — author + the `🤖 … Code Review` body header that all
# seven posted bodies share. No new body marker is introduced: LOGS_URL /
# GITHUB_RUN_ID appear only in the truncation branches (run-review.sh:1316,
# :1331) so they are not reliably present, and injecting one would touch posted
# output and have to clear LADR-067's `#`-plus-digits rule.
_GH_RETRY_BODY_MATCH='🤖 (Gemini CLI|OpenCode CLI) Code Review'

gh_count_gate_reviews() {
  local pr="${1:-}" repo="${GITHUB_REPOSITORY:-}" payload count
  [ -n "$pr" ] || return 1
  # local-review.sh runs outside Actions, where GITHUB_REPOSITORY is unset.
  # Returning 1 means "cannot verify", which degrades to a blind retry rather
  # than emitting an unbound-variable error under the caller's `set -u`.
  [ -n "$repo" ] || return 1
  payload="$(gh api "repos/${repo}/pulls/${pr}/reviews?per_page=100" 2>/dev/null)" || return 1
  [ -n "$payload" ] || return 1
  count="$(printf '%s' "$payload" | jq -r --arg m "$_GH_RETRY_BODY_MATCH" '
    [.[] | select(
      (.user.login == "github-actions[bot]") and
      ((.body // "") | test($m))
    )] | length
  ' 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$count"
}

gh_count_gate_comments() {
  local pr="${1:-}" repo="${GITHUB_REPOSITORY:-}" payload count
  [ -n "$pr" ] || return 1
  [ -n "$repo" ] || return 1
  payload="$(gh api "repos/${repo}/issues/${pr}/comments?per_page=100" 2>/dev/null)" || return 1
  [ -n "$payload" ] || return 1
  count="$(printf '%s' "$payload" | jq -r --arg m "$_GH_RETRY_BODY_MATCH" '
    [.[] | select(
      (.user.login == "github-actions[bot]") and
      ((.body // "") | test($m))
    )] | length
  ' 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$count"
}

# --- The wrapper -------------------------------------------------------------
#
# NOTE: this function must never use the variable name `_rc`. run-review.sh:463
# installs `trap '_rc=$?; assemble_run_artifacts; exit $_rc' EXIT` and `_rc` is
# an unscoped global there; shadowing it would corrupt the run's exit status.
gh_retry() {
  local counter="" counter_pr="" baseline="" after=""
  local err_file status

  while [ $# -gt 0 ]; do
    case "$1" in
      --verify)
        if [ $# -lt 3 ]; then
          echo "gh_retry: --verify needs a counter function and a PR number" >&2
          return 2
        fi
        counter="$2"
        counter_pr="$3"
        shift 3
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "gh_retry: unexpected argument '$1' — the command must follow '--'" >&2
        return 2
        ;;
    esac
  done

  if [ $# -eq 0 ]; then
    echo "gh_retry: no command given after '--'" >&2
    return 2
  fi

  # Snapshot before attempt 1, while the state is still known-good. Only when a
  # retry is actually possible — with the kill switch off there is nothing to
  # verify, so the extra read is skipped.
  if [ -n "$counter" ] && _gh_retry_enabled; then
    baseline="$("$counter" "$counter_pr" 2>/dev/null)" || baseline=""
  fi

  # Scratch file lives in TMPDIR, never under ci_temp/: the LADR-062 EXIT trap
  # reads ci_temp/{run,final_review.md,reviews,findings.merged.json} and a stray
  # sibling there is one more thing for it to trip over.
  err_file="$(mktemp "${TMPDIR:-/tmp}/gh-retry.XXXXXX")"

  status=0
  "$@" 2>"$err_file" || status=$?
  cat "$err_file" >&2

  if [ "$status" -eq 0 ]; then
    rm -f "$err_file"
    return 0
  fi

  if ! _gh_retry_enabled; then
    rm -f "$err_file"
    return "$status"
  fi

  if ! _gh_retry_is_transient < "$err_file"; then
    echo "   ℹ️  gh_retry: exit ${status} is not a known transient GitHub failure — not retrying." >&2
    rm -f "$err_file"
    return "$status"
  fi

  echo "   ⚠️  gh_retry: transient GitHub failure (exit ${status}). Waiting ${GH_RETRY_DELAY_SECONDS}s, then one retry." >&2
  sleep "$GH_RETRY_DELAY_SECONDS"

  # Did it land anyway? GitHub may have committed the mutation and lost the
  # response; re-posting would duplicate it.
  if [ -n "$counter" ] && [ -n "$baseline" ]; then
    after="$("$counter" "$counter_pr" 2>/dev/null)" || after=""
    if [ -n "$after" ] && [ "$after" -gt "$baseline" ]; then
      echo "   ✅ gh_retry: the call landed on GitHub despite the error response (${baseline} → ${after}) — not re-posting." >&2
      rm -f "$err_file"
      return 0
    fi
  fi

  echo "   🔁 gh_retry: retrying (attempt 2 of 2)." >&2
  status=0
  : > "$err_file"
  "$@" 2>"$err_file" || status=$?
  cat "$err_file" >&2
  rm -f "$err_file"

  if [ "$status" -ne 0 ]; then
    echo "   ❌ gh_retry: attempt 2 of 2 failed (exit ${status}). Giving up — no further retries." >&2
  fi
  return "$status"
}
