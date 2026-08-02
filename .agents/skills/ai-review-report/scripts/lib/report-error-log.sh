#!/bin/bash
# report-error-log.sh — preserve a diagnostic log and surface it on the console.
#
# Usage: report-error-log.sh <label> <logfile> [tail_lines]
#
# Why this exists: the gate's `Clean up temporary files` step runs
# `rm -rf ci_temp` with `if: always()`, and the gate uploads no artifact — so
# every stderr log a failing chunk produced was destroyed before anyone could
# read it. The workflow log said "📋 Stderr log: ci_temp/reviews/chunk_1_stderr.log"
# and pointed at a path that no longer existed by the time the job finished.
# PR #106 run 30756015689 lost the only evidence of why two chunks failed with
# exit 1; the cause had to be inferred from the shape of the failures instead of
# read. That is the gap this closes.
#
# Two destinations, deliberately:
#
#   1. `ci_temp_logs/` — a SIBLING of ci_temp, not a child, so the existing
#      `rm -rf ci_temp` cannot reach it. Survives to the end of the job and to
#      any later step that wants to upload it.
#   2. The console — the only channel that outlives the runner. GitHub keeps
#      workflow logs; it does not keep the workspace. Wrapped in a `::group::`
#      so a long dump stays collapsed and does not drown the review output.
#
# Bounded on purpose: a model/CLI failure can emit megabytes of retry spam, and
# an unbounded dump would push the actual review out of the readable part of the
# log. The tail is where the terminal error lives.
#
# Secret safety: this prints CLI stderr, which is why the gate's credentials are
# GitHub **Secrets** rather than Variables — Actions masks registered secret
# values in log output automatically. Never widen this to print a prompt file or
# an environment dump, neither of which is masked.
#
# Never fails the caller: this runs on paths that are already handling an error,
# and a diagnostic helper that can itself abort the run is worse than no
# diagnostic at all. Always exits 0.
set -uo pipefail

label="${1:-unknown}"
logfile="${2:-}"
tail_lines="${3:-${OPENCODE_REVIEW_REPORT_ERROR_LOG_LINES:-40}}"

# Sanitise the label — it becomes a filename and a log-group title.
safe_label="$(printf '%s' "$label" | tr -cs '[:alnum:]._-' '_')"
LOG_DIR="${OPENCODE_REVIEW_REPORT_LOG_DIR:-ci_temp_logs}"

if ! [[ "$tail_lines" =~ ^[0-9]+$ ]] || [ "$tail_lines" -le 0 ]; then
  tail_lines=40
fi

if [ -z "$logfile" ] || [ ! -f "$logfile" ]; then
  echo "  📋 No diagnostic log captured for ${label} (expected: ${logfile:-<none>})"
  exit 0
fi

mkdir -p "$LOG_DIR" 2>/dev/null || true
if [ -d "$LOG_DIR" ]; then
  cp "$logfile" "$LOG_DIR/${safe_label}.log" 2>/dev/null \
    && echo "  💾 Diagnostic log preserved: ${LOG_DIR}/${safe_label}.log"
fi

if [ ! -s "$logfile" ]; then
  echo "  📋 Diagnostic log for ${label} is empty — the failure produced no stderr"
  exit 0
fi

size=$(wc -c < "$logfile" 2>/dev/null | tr -d ' ')
total=$(wc -l < "$logfile" 2>/dev/null | tr -d ' ')

# `::group::` is GitHub Actions syntax; plain headers everywhere else so local
# runs stay readable.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::group::📋 Diagnostic log — ${label} (last ${tail_lines} of ${total} lines, ${size} bytes)"
else
  echo "  ── Diagnostic log — ${label} (last ${tail_lines} of ${total} lines, ${size} bytes) ──"
fi

tail -n "$tail_lines" "$logfile" 2>/dev/null | sed 's/^/    /'

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::endgroup::"
else
  echo "  ── end ${label} ──"
fi

exit 0
