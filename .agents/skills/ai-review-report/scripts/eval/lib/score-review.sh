#!/bin/bash
# score-review.sh — parse a chunk-review markdown and report which severities
# carry a real, blocking finding.
#
# Reuses the pipeline's flag grammar (LADR-012 / LADR-015) for the eval harness
# introduced by LADR-033:
#   - Only [VERIFIED] findings count. [SPECULATIVE] never blocks, so it is never
#     scored as a flag (mirrors the gate: only [VERIFIED] Critical/High can block).
#   - The per-file output template (review-in-chunks.sh) always prints all four
#     severity lines with "None found" for the empty ones, so a "None found"
#     placeholder is NOT a flag. The placeholder match is case-insensitive and
#     tolerates quoted / bolded / period-terminated variants (same shape as the
#     aggregation placeholder strip in LADR-030).
#   - The severity keyword must appear in the LABEL (text before the first colon)
#     so a High-priority finding whose *description* mentions the word "critical"
#     is not miscounted as a Critical flag.
#
# Usage:  score-review.sh <review.md>      (or pipe the review on stdin)
# Output: one severity token per line, from {CRITICAL,HIGH,MEDIUM}, for each that
#         has at least one real verified finding. Empty output = clean (no
#         blocking findings). Always exits 0 — this is a parser, not a gate.

set -euo pipefail

input="${1:-/dev/stdin}"

# Is the text after the severity label a "None found"-style placeholder (i.e. NOT
# a real finding)? Strips markdown emphasis/quotes/backticks, surrounding space,
# and a trailing period, then matches a small set of empty phrasings.
_is_none() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[`*"'"'"']//g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/\.+$//')"
  [ -z "$s" ] && return 0
  case "$s" in
    none|"none found"|"none identified"|"none present"|"none noted"|"none detected" \
      |"no issues"|"no issues found"|"no concerns"|"no concerns found" \
      |"no problems"|"no problems found"|"nothing found"|"none found in test run" \
      |n/a|na) return 0 ;;
    *) return 1 ;;
  esac
}

# Does any [VERIFIED] line carry this severity in its label with a non-placeholder
# payload? $1 = case-insensitive ERE matching the severity keyword in the label.
_sev_flagged() {
  local keyword="$1" line label payload
  while IFS= read -r line; do
    # Strip a `(confidence: N)` parenthetical before splitting. The label is
    # defined as everything before the FIRST colon, so a parenthetical that
    # contains its own colon moves the split point and takes the payload with
    # it: `- 🔴 [VERIFIED] Critical (confidence: 100): None found` split into
    # label `- 🔴 [VERIFIED] Critical (confidence` — still matching [VERIFIED]
    # and the severity — and payload ` 100): None found`, which _is_none does
    # not recognise. Every "None found" placeholder then scored as a real flag,
    # and DR-001 failed with three of them (run 30795770815).
    #
    # The reviewer is not told to emit this; it volunteers the anchor it was
    # asked for by LADR-055 into the markdown label. Since model formatting
    # cannot be relied on, the scorer normalises rather than the prompt
    # forbidding — a prompt rule here would be model-trusted, and the failure
    # mode is silent miscounting in the one instrument meant to catch that.
    line="$(printf '%s' "$line" | sed -E 's/\([Cc]onfidence:[^)]*\)//g')"
    # Finding lines are "…: <payload>". No colon → not a finding line.
    label="${line%%:*}"
    [ "$label" = "$line" ] && continue
    payload="${line#*:}"
    printf '%s' "$label" | grep -qiE '\[VERIFIED\]' || continue
    printf '%s' "$label" | grep -qiE "(^|[^a-z])${keyword}([^a-z]|\$)" || continue
    _is_none "$payload" || return 0
  done < "$input"
  return 1
}

_sev_flagged 'critical'                    && echo "CRITICAL"
_sev_flagged 'high([[:space:]]+priority)?' && echo "HIGH"
_sev_flagged 'medium([[:space:]]+priority)?' && echo "MEDIUM"

exit 0
