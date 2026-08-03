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
# Usage:  score-review.sh [--lines] <review.md>   (or pipe the review on stdin)
# Output (default): one severity token per line, from {CRITICAL,HIGH,MEDIUM}, for
#         each that has at least one real verified finding. Empty output = clean
#         (no blocking findings). Always exits 0 — this is a parser, not a gate.
# Output (--lines): one `SEVERITY<TAB><finding line>` record per flagged finding,
#         for callers that must decide something from the finding TEXT — e.g. the
#         must-not-flag DR-claim match in run-evals.sh.
#
# --lines exists so there is exactly ONE implementation of "what counts as a
# flagged finding". A second copy of the [VERIFIED] + severity-in-label +
# not-a-placeholder rules would drift from this one, and this repo has already
# paid for that once (a test asserting against a reproduction of a validator
# that had silently diverged from the real thing).

set -euo pipefail

mode="tokens"
if [ "${1:-}" = "--lines" ]; then
  mode="lines"
  shift
fi
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
  local keyword="$1" line label payload orig found=1
  while IFS= read -r line; do
    orig="$line"
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
    if _is_none "$payload"; then
      continue
    fi
    if [ "$mode" = "lines" ]; then
      # Emit every flagged finding, not just the first — the caller needs all of
      # them to decide whether ANY matches the forbidden claim.
      printf '%s\t%s\n' "$2" "$orig"
      found=0
    else
      return 0
    fi
  done < "$input"
  [ "${found:-1}" -eq 0 ] && return 0
  return 1
}

if [ "$mode" = "lines" ]; then
  _sev_flagged 'critical'                      CRITICAL || true
  _sev_flagged 'high([[:space:]]+priority)?'   HIGH     || true
  _sev_flagged 'medium([[:space:]]+priority)?' MEDIUM   || true
else
  _sev_flagged 'critical'                    && echo "CRITICAL"
  _sev_flagged 'high([[:space:]]+priority)?' && echo "HIGH"
  _sev_flagged 'medium([[:space:]]+priority)?' && echo "MEDIUM"
fi

exit 0
