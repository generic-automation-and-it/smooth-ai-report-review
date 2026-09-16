#!/bin/bash
# split-chunk-budget.sh — split a chunk's review budget across the two-tier chain.
#
# Usage:  read -r primary secondary < <(bash lib/split-chunk-budget.sh <total_seconds>)
#
# Prints "<primary_seconds> <secondary_seconds>" on stdout and nothing else; any
# complaint about a bad value goes to stderr so the caller's read stays two bare
# integers. A secondary of `0` means **do not split** — the caller hands the whole
# budget to the primary and the behaviour is byte-identical to the pre-split gate.
#
# Why this exists (LADR-081). `validate-chunk-timeout.sh` decides how long a chunk
# gets; this decides who gets to spend it. The gate wrapped ONE `timeout` around
# `lib/opencode-with-fallback.sh`, which has no internal per-model budget, so an
# exit 124 meant the primary had consumed the entire allowance and the LADR-002
# secondary was never invoked — the chain exists to rescue exactly the case a
# timeout produces, and the wrap silently switched it off. LADR-066 already fixed
# this shape for the grouping call by splitting 60 s into 35 s + 25 s; this is the
# same fix for the chunk chain, which is where it actually costs reviews.
#
# The split is deliberately NOT a plain percentage. A chunk that legitimately
# needs 300 s must keep succeeding on the primary: the slowest chunk that has ever
# SUCCEEDED took 299 s (68 KB under 6-way concurrency), so shaving the primary
# below that trades a rare rescued chunk for a common broken one. Hence a floor on
# the primary and a floor on the secondary, and — when both cannot be honoured —
# no split at all rather than a split that starves a stage.
#
# Consequence worth knowing before you retune: at the DEFAULT 450 s base there is
# no room, so the default configuration is unchanged and this lib is inert. The
# split switches on at 480 s and above, which is why the consumer that motivated
# it (base 700 s) gets the fix and nobody else's timing moves.

set -uo pipefail

# 35%: the secondary is the rescue tier, not a co-equal. It needs enough to write
# a review, not enough to repeat the primary's exploration.
SECONDARY_SHARE_PCT=35

# Above the 299 s slowest observed success, with room for the trend that made
# LADR-065 necessary. The primary must never be squeezed under the envelope in
# which chunks are known to pass.
PRIMARY_MIN_SECONDS=330

# Below this a second full chunk review cannot finish, so reserving it would
# convert a working single-tier attempt into two failing ones.
SECONDARY_MIN_SECONDS=150

_total="${1:-}"

# Invalid input is not guessed at: printing "0 0" makes the caller's own guard
# fire (it falls back to the unsplit budget it already holds) rather than this
# lib inventing a budget nobody validated. `^[1-9][0-9]*$` matches
# validate-chunk-timeout.sh's rule, including its rejection of `007`.
if ! [[ "$_total" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ split-chunk-budget.sh: total='${_total}' is not a positive integer — no split" >&2
  printf '0 0'
  exit 0
fi

_secondary=$(( _total * SECONDARY_SHARE_PCT / 100 ))
_primary=$(( _total - _secondary ))

# Honour the primary floor first: it protects chunks that already work, and a
# rescue tier is worth less than not breaking the common path.
if [ "$_primary" -lt "$PRIMARY_MIN_SECONDS" ]; then
  _primary="$PRIMARY_MIN_SECONDS"
  _secondary=$(( _total - _primary ))
fi

# No room for both floors → don't split. The caller keeps today's single wrap,
# and the failure marker says the secondary was not reached (which is true).
if [ "$_secondary" -lt "$SECONDARY_MIN_SECONDS" ]; then
  printf '%s 0' "$_total"
  exit 0
fi

printf '%s %s' "$_primary" "$_secondary"
