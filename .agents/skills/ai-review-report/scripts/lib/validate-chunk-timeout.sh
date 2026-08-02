#!/bin/bash
# validate-chunk-timeout.sh — resolve the per-chunk review budget, in seconds.
#
# Usage:  _chunk_timeout="$(bash lib/validate-chunk-timeout.sh)"
#
# Prints the validated value of `OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT` on
# stdout and nothing else; any complaint about a bad value goes to stderr so
# the caller's command substitution stays a bare integer.
#
# Why this is a lib rather than four lines at the call site: the budget wraps
# the WHOLE model chain (`lib/opencode-with-fallback.sh` has no internal
# per-model timeout), so a wrong value here does not degrade gracefully — it
# fail-closes a chunk that would have reviewed fine, and denies the LADR-002
# secondary its turn. That makes the validation load-bearing, and load-bearing
# logic has to be testable against the real source.
#
# It previously was not. `test-review-chunk-threshold.sh` pinned the
# fallback-on-bad-value contract with a self-contained subshell REPRODUCTION of
# the validator, which had drifted to `^[0-9]+$` while the real call site used
# `^[1-9][0-9]*$` — the two disagree on leading zeros (`007`: real → 450,
# reproduction → passes `007` straight through to `timeout`). Worse, the only
# assertion tying the test to the real script was a `grep -c` for the variable
# name, which stays green even if the validation is deleted outright. One
# definition, sourced by both, is the fix.
set -uo pipefail

# The default is measurement, not caution: the slowest chunk that has ever
# SUCCEEDED on the deployed pair took 209 s, so 450 is >2x the observed worst
# case, and doubles as a deadlock detector — past roughly that point a chunk is
# stuck rather than slow, and waiting it out only holds the job open.
CHUNK_TIMEOUT_DEFAULT=450

_t="${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:-$CHUNK_TIMEOUT_DEFAULT}"

# `^[1-9][0-9]*$` and not `^[0-9]+$ && > 0`: it rejects the empty string, junk,
# negatives, `0`, AND leading-zero forms like `007`, which `timeout` would
# otherwise accept as a value nobody intended to write.
if ! [[ "$_t" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT='${_t}' is not a positive integer — falling back to ${CHUNK_TIMEOUT_DEFAULT}s" >&2
  _t="$CHUNK_TIMEOUT_DEFAULT"
fi

printf '%s' "$_t"
