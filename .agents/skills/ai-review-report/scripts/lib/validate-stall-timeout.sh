#!/bin/bash
# validate-stall-timeout.sh — resolve the per-chunk stall threshold, in seconds.
#
# Usage:  _stall_secs="$(bash lib/validate-stall-timeout.sh)"
#
# Prints the validated value of `OPENCODE_REVIEW_REPORT_STALL_TIMEOUT` on stdout
# and nothing else; any complaint about a bad value goes to stderr so the
# caller's command substitution stays a bare integer.
#
# Why this is a lib rather than four lines at the call site: the threshold wraps
# a KILL, so a wrong value here does not degrade gracefully — too low and it
# kills honest chunks mid-review, which is the same fail-closed REQUEST_CHANGES
# the budget was calibrated to avoid. That makes the validation load-bearing,
# and load-bearing logic has to be testable against the real source rather than
# a reimplementation of it (the lesson `validate-chunk-timeout.sh` records about
# its own test drifting away from the call site).
#
# Resolution, in order:
#   unset / blank        -> STALL_DEFAULT (default ON)
#   0                    -> 0, i.e. the detector is OFF (kill-switch alias for
#                           OPENCODE_REVIEW_REPORT_ENABLE_STALL_DETECTOR)
#   ^[1-9][0-9]*$        -> used as-is
#   anything else        -> warn on stderr, fall back to STALL_DEFAULT
#
# `^[1-9][0-9]*$` rather than `^[0-9]+$ && > 0` for the same reason
# validate-chunk-timeout.sh uses it: it rejects the empty string, junk,
# negatives, `0` (handled above as the off-switch) AND leading-zero forms like
# `007`, which `sleep` would otherwise accept as a value nobody intended.
set -uo pipefail

# 240 s, not a tighter number. A model that is genuinely working streams tool
# events continuously (that stream is the whole signal — see stall-watchdog.sh),
# so 240 s of absolute silence is not a slow model, it is a hung one. The
# failure this exists for burned 650 s of a 1000 s budget before anything
# reacted (run 36837246807, 10m50s of a 17m19s gate run); killing at 240 s
# instead is the difference between ~17.5 min and ~8.5 min on that shape.
# Constraint 4 of the design: this must stay generous enough that a model
# thinking for 60 s between tool calls on a 135 KB prompt is never killed.
STALL_DEFAULT=240

_t="${OPENCODE_REVIEW_REPORT_STALL_TIMEOUT:-$STALL_DEFAULT}"

# Blank means "use the default" at every layer, matching the way the
# OPENCODE_REVIEW_REPORT_ENABLE_* toggles are read elsewhere in this repo: an
# unset Variable and an explicitly empty one are the same request.
if [ -z "${_t//[[:space:]]/}" ]; then
  _t="$STALL_DEFAULT"
fi

# `0` (and only `0`) is the off-switch on this variable. Handled before the
# pattern so the pattern can stay strict about leading zeros.
if [ "$_t" = "0" ]; then
  printf '0'
  exit 0
fi

if ! [[ "$_t" =~ ^[1-9][0-9]*$ ]]; then
  echo "⚠️ OPENCODE_REVIEW_REPORT_STALL_TIMEOUT='${_t}' is not a positive integer — falling back to ${STALL_DEFAULT}s" >&2
  _t="$STALL_DEFAULT"
fi

printf '%s' "$_t"