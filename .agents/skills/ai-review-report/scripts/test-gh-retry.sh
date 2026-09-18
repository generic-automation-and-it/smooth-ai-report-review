#!/bin/bash
set -e

# Test script for lib/gh-retry.sh (LADR-078).
#
# The regression under test: on 2026-09-13 GitHub's write path degraded for ~40
# minutes without ever appearing on its status page, and because run-review.sh
# runs under `set -euo pipefail` with every gh call unguarded, a single
# transient 5xx aborted the run. Three reviews that had already been generated
# in full — body assembled, verdict computed — were discarded by one failed
# mutation (runs 34748824725 and 34749107099 here, plus PR 18 on
# smooth-ai-product-context-memory).
#
# The oracles that matter are Tests 3 and 5. Test 3 pins that "one retry" means
# exactly two attempts and never a third. Test 5 pins that the classifier is an
# ALLOWLIST: a 4xx must fail fast, so the wrapper can never make a genuine
# client error slower or double-post it.
#
# Offline: `gh` is a stub on PATH replaying a scripted response sequence. No
# network, no model calls. GH_RETRY_DELAY_SECONDS=0 keeps the suite fast.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/gh-retry.sh"

TMP_DIR="$(mktemp -d)"
# SUITE_COMPLETED is flipped to 1 on the last line. Without this, a `set -e`
# abort mid-suite exits non-zero but prints a screen full of ✅ and no summary,
# which reads exactly like a pass to anyone skimming.
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$TMP_DIR"; if [ "$SUITE_COMPLETED" != "1" ]; then echo ""; echo "❌ SUITE ABORTED EARLY (exit $rc) — assertions after this point never ran"; fi' EXIT

echo "=========================================="
echo "Testing gh-retry.sh"
echo "=========================================="
echo ""

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---"; printf '%s\n' "$actual"
    fail=$((fail + 1))
  fi
}

# --- The gh stub -------------------------------------------------------------
# Dispatches on $1: `api` is a verifier read, anything else is the write under
# test. Each path has its own call log and its own scripted response sequence,
# so verifier reads never consume the write script's lines.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "api" ]; then
  echo "$*" >> "$GH_VERIFY_LOG"
  if [ "${GH_VERIFY_FAIL:-0}" = "1" ]; then
    echo "gh: stubbed verifier read failure" >&2
    exit 1
  fi
  n=$(wc -l < "$GH_VERIFY_LOG" | tr -d ' ')
  count="$(sed -n "${n}p" "$GH_VERIFY_COUNTS" 2>/dev/null)"
  [ -n "$count" ] || count="$(tail -1 "$GH_VERIFY_COUNTS" 2>/dev/null)"
  [ -n "$count" ] || count=0
  # Emit `count` entries that match the lib's author + body-header filter.
  printf '['
  i=0
  while [ "$i" -lt "$count" ]; do
    [ "$i" -gt 0 ] && printf ','
    printf '{"user":{"login":"github-actions[bot]"},"body":"## 🤖 OpenCode CLI Code Review - Commit: `abc1234`"}'
    i=$((i + 1))
  done
  printf ']\n'
  exit 0
fi
echo "$*" >> "$GH_WRITE_LOG"
n=$(wc -l < "$GH_WRITE_LOG" | tr -d ' ')
line="$(sed -n "${n}p" "$GH_WRITE_SCRIPT" 2>/dev/null)"
[ -n "$line" ] || line="$(tail -1 "$GH_WRITE_SCRIPT" 2>/dev/null)"
code="${line%%|*}"
err="${line#*|}"
[ -n "$err" ] && printf '%s\n' "$err" >&2
exit "${code:-0}"
STUB
chmod +x "$TMP_DIR/bin/gh"
export PATH="$TMP_DIR/bin:$PATH"

export GITHUB_REPOSITORY="acme/widget"
export GH_RETRY_DELAY_SECONDS=0
export GH_WRITE_LOG="$TMP_DIR/write.log"
export GH_VERIFY_LOG="$TMP_DIR/verify.log"
export GH_WRITE_SCRIPT="$TMP_DIR/write.script"
export GH_VERIFY_COUNTS="$TMP_DIR/verify.counts"
export GH_VERIFY_FAIL=0

# shellcheck disable=SC1090
source "$LIB"

# reset <write-script-lines...> — clears logs and arms the write sequence.
reset() {
  : > "$GH_WRITE_LOG"
  : > "$GH_VERIFY_LOG"
  : > "$GH_VERIFY_COUNTS"
  export GH_VERIFY_FAIL=0
  export OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY=1
  printf '%s\n' "$@" > "$GH_WRITE_SCRIPT"
}

calls() { wc -l < "$GH_WRITE_LOG" | tr -d ' '; }

BAD_GATEWAY='0|'
BAD_GATEWAY='1|failed to create review: non-200 OK status code: 502 Bad Gateway body: "<html>"'
GRAPHQL_500='1|failed to create review: GraphQL: Something went wrong while executing your query on 2026-09-13T09:19:28Z.'
VALIDATION='1|gh: Validation Failed (HTTP 422)'
OK='0|'

# --- Test 1: success on attempt 1 -------------------------------------------
reset "$OK"
status=0
gh_retry -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 1: success on attempt 1 returns 0" "0" "$status"
check "Test 1b: success on attempt 1 makes exactly one call" "1" "$(calls)"

# --- Test 2: transient 502 then success --------------------------------------
reset "$BAD_GATEWAY" "$OK"
status=0
gh_retry -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 2: 502 then success returns 0" "0" "$status"
check "Test 2b: 502 then success makes exactly two calls" "2" "$(calls)"

# --- Test 3: transient twice → give up at two attempts, never a third --------
reset "$BAD_GATEWAY" "$BAD_GATEWAY" "$OK"
status=0
gh_retry -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 3: two transient failures propagate non-zero" "1" "$status"
check "Test 3b: exactly two attempts — no third even though the script would succeed" "2" "$(calls)"

# --- Test 4: today's exact GraphQL 500 signature is classified transient -----
reset "$GRAPHQL_500" "$OK"
status=0
gh_retry -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 4: 'Something went wrong while executing your query' is retryable" "0" "$status"
check "Test 4b: GraphQL 500 retried exactly once" "2" "$(calls)"

# --- Test 5: allowlist, not denylist — a 4xx fails fast ----------------------
reset "$VALIDATION" "$OK"
status=0
gh_retry -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 5: HTTP 422 propagates non-zero without retrying" "1" "$status"
check "Test 5b: HTTP 422 makes exactly one call" "1" "$(calls)"

# --- Test 6: verifier says the mutation landed → do not re-post --------------
# Baseline read returns 0, post-failure read returns 1 → delta detected.
reset "$BAD_GATEWAY" "$OK"
printf '0\n1\n' > "$GH_VERIFY_COUNTS"
status=0
gh_retry --verify gh_count_gate_reviews 7 -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 6: a landed mutation returns 0" "0" "$status"
check "Test 6b: a landed mutation is NOT re-posted (one write only)" "1" "$(calls)"

# --- Test 7: verifier read fails → retry anyway (duplicate over silence) -----
reset "$BAD_GATEWAY" "$OK"
export GH_VERIFY_FAIL=1
status=0
gh_retry --verify gh_count_gate_reviews 7 -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
export GH_VERIFY_FAIL=0
check "Test 7: unverifiable state still retries" "0" "$status"
check "Test 7b: unverifiable state makes two calls" "2" "$(calls)"

# --- Test 7c: verifier shows no delta → retry --------------------------------
reset "$BAD_GATEWAY" "$OK"
printf '0\n0\n' > "$GH_VERIFY_COUNTS"
status=0
gh_retry --verify gh_count_gate_reviews 7 -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
check "Test 7c: no count delta means not landed, so it retries" "2" "$(calls)"

# --- Test 8: kill switch off → single attempt, status passes through ---------
reset "$BAD_GATEWAY" "$OK"
export OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY=0
status=0
gh_retry -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || status=$?
export OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY=1
check "Test 8: kill switch off propagates the original failure" "1" "$status"
check "Test 8b: kill switch off makes exactly one call" "1" "$(calls)"

# --- Test 8c: kill switch off skips the baseline verifier read entirely ------
reset "$OK"
export OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY=0
gh_retry --verify gh_count_gate_reviews 7 -- gh pr review 7 --approve --body-file body.md >/dev/null 2>&1 || true
export OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY=1
check "Test 8c: kill switch off costs no verifier read" "0" "$(wc -l < "$GH_VERIFY_LOG" | tr -d ' ')"

# --- Test 9: stdout passes through untouched (read sites capture it) ---------
# The read sites use PR_JSON="$(gh_retry -- gh api ...)" so stdout must survive.
reset "$OK"
printf '5\n' > "$GH_VERIFY_COUNTS"
captured="$(gh_retry -- gh api "repos/acme/widget/pulls/7" 2>/dev/null)"
# The payload is one line, so count occurrences rather than matching lines.
check "Test 9: stdout is passed through to the caller's capture" "5" \
  "$(printf '%s' "$captured" | grep -o 'github-actions' | wc -l | tr -d ' ')"

# --- Test 10: a non-zero final status still aborts a `set -e` caller ---------
# Run the probe as its OWN bash process. A `( set -e; … ) || x=y` subshell would
# prove nothing: errexit is ignored for any command of an AND-OR list other than
# the last, and bash propagates that suppression into the subshell — the probe
# would never abort no matter how the wrapper behaved.
reset "$BAD_GATEWAY" "$BAD_GATEWAY"
export LIB_PATH="$LIB"
export AFTER_FILE="$TMP_DIR/after_abort"
rm -f "$AFTER_FILE"
cat > "$TMP_DIR/abort_probe.sh" <<'PROBE'
set -e
# shellcheck disable=SC1090
source "$LIB_PATH"
gh_retry -- gh pr review 7 --approve --body-file body.md
echo "reached" > "$AFTER_FILE"
PROBE
aborted="no"
bash "$TMP_DIR/abort_probe.sh" >/dev/null 2>&1 || aborted="yes"
check "Test 10: exhausted retry aborts a set -e caller" "yes" "$aborted"
check "Test 10b: nothing after the failed call runs" "absent" \
  "$([ -f "$AFTER_FILE" ] && echo present || echo absent)"

# --- Test 11: bad usage is rejected, not silently run ------------------------
reset "$OK"
status=0
gh_retry gh pr review 7 >/dev/null 2>&1 || status=$?
check "Test 11: a command without '--' is rejected" "2" "$status"
check "Test 11b: a rejected invocation runs nothing" "0" "$(calls)"

# --- Structural guards ------------------------------------------------------
# The failure was one unwrapped call. Pin that every site stays wrapped rather
# than trusting a reviewer to notice a bare `gh pr review` being pasted back in.
# Comments are stripped first: the surviving prose deliberately quotes the old
# shape to explain why it is gone, and must not trip its own guard.
RR="$SCRIPT_DIR/run-review.sh"
LR="$SCRIPT_DIR/local-review.sh"
RR_CODE="$TMP_DIR/run-review.code"
LR_CODE="$TMP_DIR/local-review.code"
LIB_CODE="$TMP_DIR/gh-retry.code"
grep -v '^[[:space:]]*#' "$RR" > "$RR_CODE"
grep -v '^[[:space:]]*#' "$LR" > "$LR_CODE"
grep -v '^[[:space:]]*#' "$LIB" > "$LIB_CODE"

# Test 12: every `gh pr review` / `gh pr comment` is a gh_retry continuation.
# Any occurrence whose previous line does not end in `-- \` is unwrapped.
unwrapped="$(awk '
  /gh pr (review|comment)/ {
    if (prev !~ /gh_retry .* -- \\$/) c++
  }
  { prev = $0 }
  END { print c + 0 }
' "$RR_CODE")"
check "Test 12: no unwrapped gh pr review/comment in run-review.sh" "0" "$unwrapped"

unwrapped_lr="$(awk '
  /gh pr (review|comment)/ {
    if (prev !~ /gh_retry .* -- \\$/) c++
  }
  { prev = $0 }
  END { print c + 0 }
' "$LR_CODE")"
check "Test 12b: no unwrapped gh pr review/comment in local-review.sh" "0" "$unwrapped_lr"

# Test 13: the PR-metadata reads go through the wrapper too.
unwrapped_read="$(grep -c 'PR_JSON="\$(gh api' "$RR_CODE" || true)"
check "Test 13: no PR_JSON read bypasses gh_retry" "0" "$unwrapped_read"

# Test 14: wrapped-site counts match the LADR-078 scope (9 + 3).
check "Test 14: run-review.sh has 9 gh_retry sites" "9" "$(grep -c 'gh_retry ' "$RR_CODE" || true)"
check "Test 14b: local-review.sh has 3 gh_retry sites" "3" "$(grep -c 'gh_retry --verify' "$LR_CODE" || true)"

# Test 15: fixed delay, not a ramp. One sleep, no doubling arithmetic.
check "Test 15: exactly one sleep in the lib" "1" "$(grep -c 'sleep "\$GH_RETRY_DELAY_SECONDS"' "$LIB_CODE" || true)"
if grep -qE 'DELAY_SECONDS \* 2|\* 2\)|<< 1|backoff=|attempt \* ' "$LIB_CODE"; then
  ramp="present"
else
  ramp="absent"
fi
check "Test 15b: no exponential-backoff arithmetic survives" "absent" "$ramp"

# Test 16: the delay default is 30s.
check "Test 16: default delay is 30 seconds" "1" "$(grep -c 'GH_RETRY_DELAY_SECONDS:-30' "$LIB_CODE" || true)"

# Test 17: the lib must not shadow run-review.sh's EXIT-trap global `_rc`.
if grep -qE '(^|[^A-Za-z_])_rc=' "$LIB_CODE"; then
  collision="present"
else
  collision="absent"
fi
check "Test 17: lib does not shadow the EXIT trap's _rc global" "absent" "$collision"

# Test 18: the kill switch is declared in BOTH workflow packagings.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
for f in ".github/workflows/pipeline-code-review-report.yml" ".docs/examples/code-review-local.yml"; do
  if grep -q 'OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY' "$REPO_ROOT/$f" 2>/dev/null; then
    declared="yes"
  else
    declared="no"
  fi
  check "Test 18: ENABLE_GH_RETRY declared in $f" "yes" "$declared"
done

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
SUITE_COMPLETED=1
[ "$fail" -eq 0 ]
