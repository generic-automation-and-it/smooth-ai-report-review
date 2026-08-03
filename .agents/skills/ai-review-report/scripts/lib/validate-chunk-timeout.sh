#!/bin/bash
# validate-chunk-timeout.sh — resolve the per-chunk review budget, in seconds.
#
# Usage:  _chunk_timeout="$(bash lib/validate-chunk-timeout.sh [prompt_bytes])"
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

# The base is measurement, not caution: the slowest chunk that has ever
# SUCCEEDED on the deployed pair took 209 s, so 450 is >2x that, and doubles as
# a deadlock detector — past roughly that point a chunk is stuck rather than
# slow, and waiting it out only holds the job open.
CHUNK_TIMEOUT_DEFAULT=450

# ...but a FIXED budget against VARIABLE work fail-closes honest chunks, which
# is what it did on PR #111 run 30792984316: 4 of 6 chunks died at exactly 450 s
# (exit 124) on 135 KB prompts. The trend across runs is unambiguous — 88 KB
# prompts: 0 timeouts; ~107 KB: 1; 135 KB: 4. The 450 s was calibrated when a
# chunk prompt was ~88 KB; instruction growth since (LADR-055 ~+8 KB, LADR-058
# ~+7.9 KB, ~33 KB of instructions in total) rides on top of a diff that the
# chunker already allows up to MAX_CHUNK_SIZE, so the same 100 KB of code now
# ships as a 135 KB prompt against the same clock.
#
# So the budget scales with the prompt and stays bounded at both ends:
#   floor    the base above, so small chunks are unaffected
#   slope    +SECONDS_PER_KB for every KB beyond FREE_KB
#   ceiling  CHUNK_TIMEOUT_MAX, which preserves the deadlock-detector property
#
# Slope from the same run's successful chunks: 43 KB → 113 s (2.6 s/KB) and
# 68 KB → 299 s (4.4 s/KB), both under 6-way concurrency. 6 s/KB is ~1.4x the
# worst observed rate; the ceiling stops that extrapolation running away on a
# prompt near the LADR-035 maximum.
CHUNK_TIMEOUT_MAX_DEFAULT=1200
CHUNK_TIMEOUT_FREE_KB=64
CHUNK_TIMEOUT_SECONDS_PER_KB=6

_t="${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:-$CHUNK_TIMEOUT_DEFAULT}"
_max="${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX:-$CHUNK_TIMEOUT_MAX_DEFAULT}"
_prompt_bytes="${1:-0}"

# `^[1-9][0-9]*$` and not `^[0-9]+$ && > 0`: it rejects the empty string, junk,
# negatives, `0`, AND leading-zero forms like `007`, which `timeout` would
# otherwise accept as a value nobody intended to write.
if ! [[ "$_t" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT='${_t}' is not a positive integer — falling back to ${CHUNK_TIMEOUT_DEFAULT}s" >&2
  _t="$CHUNK_TIMEOUT_DEFAULT"
fi

if ! [[ "$_max" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX='${_max}' is not a positive integer — falling back to ${CHUNK_TIMEOUT_MAX_DEFAULT}s" >&2
  _max="$CHUNK_TIMEOUT_MAX_DEFAULT"
fi
# A ceiling below the floor is a contradiction; the floor wins, because
# fail-closing an honest chunk is the worse outcome.
if [ "$_max" -lt "$_t" ]; then
  _max="$_t"
fi

# Scale only when the caller supplied a usable prompt size. No argument (or a
# junk one) keeps the pre-scaling behaviour exactly, so every existing caller
# and test is unaffected.
if [[ "$_prompt_bytes" =~ ^[0-9]+$ ]] && [ "$_prompt_bytes" -gt 0 ]; then
  _kb=$(( _prompt_bytes / 1024 ))
  if [ "$_kb" -gt "$CHUNK_TIMEOUT_FREE_KB" ]; then
    _scaled=$(( _t + (_kb - CHUNK_TIMEOUT_FREE_KB) * CHUNK_TIMEOUT_SECONDS_PER_KB ))
    [ "$_scaled" -gt "$_max" ] && _scaled="$_max"
    if [ "$_scaled" -gt "$_t" ]; then
      echo "⏱️  Chunk prompt is ${_kb} KB — scaling the review budget ${_t}s → ${_scaled}s (ceiling ${_max}s)" >&2
      _t="$_scaled"
    fi
  fi
fi

printf '%s' "$_t"
