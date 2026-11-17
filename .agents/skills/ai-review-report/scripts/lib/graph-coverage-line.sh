#!/bin/bash
# graph-coverage-line.sh — the single Coverage line for graph enrichment that an
# ENABLED feature could not deliver (LADR-050 amendment, R13).
#
# Usage: bash graph-coverage-line.sh <graph_state.json>
# Prints one markdown bullet, or nothing. Always exits 0.
#
# Only an enabled feature's degradation is reported, and only from facts:
#   - churn requested (OPENCODE_REVIEW_REPORT_GRAPH_CHURN) and the graph said
#     churn_status "unavailable" → "churn unavailable"
#   - removed-symbol hints on (OPENCODE_REVIEW_REPORT_GRAPH_REMOVED_SIGNALS) and a
#     parsed graph_version < 2.4.0 → "deleted-symbol hints unavailable (graph < 2.4.0)"
#   - graph signals on (OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS, default on) and a
#     parsed graph_version < 2.3.9 → "test-gap classification unavailable (graph < 2.3.9)"
# The version clauses are driven by graph_version alone, never by a missing
# per-entry field. Routine state (churn ok/off), an unknown version, and a graph
# that did not run (GRAPH_ANALYSIS_AVAILABLE other than "true") print nothing.
set -u

STATE="${1:-}"
[ -n "$STATE" ] || exit 0

flag_on() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'
}

# 0 when $1 < $2 for x.y.z versions; a non-version never compares as older.
version_lt() {
  printf '%s' "$1" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' || return 1
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$((10#$a1))" -ne "$((10#$b1))" ] && { [ "$((10#$a1))" -lt "$((10#$b1))" ]; return; }
  [ "$((10#$a2))" -ne "$((10#$b2))" ] && { [ "$((10#$a2))" -lt "$((10#$b2))" ]; return; }
  [ "$((10#$a3))" -lt "$((10#$b3))" ]
}

[ "${GRAPH_ANALYSIS_AVAILABLE:-}" = "true" ] || exit 0
[ -s "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

version="$(jq -r '.graph_version // "" | strings' "$STATE" 2>/dev/null || true)"
churn="$(jq -r '.churn_status // "" | strings' "$STATE" 2>/dev/null || true)"

parts=()
if flag_on "${OPENCODE_REVIEW_REPORT_GRAPH_CHURN:-0}" && [ "$churn" = "unavailable" ]; then
  parts+=("churn unavailable")
fi
if flag_on "${OPENCODE_REVIEW_REPORT_GRAPH_REMOVED_SIGNALS:-0}" && version_lt "$version" 2.4.0; then
  parts+=("deleted-symbol hints unavailable (graph < 2.4.0)")
fi
if flag_on "${OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS:-1}" && version_lt "$version" 2.3.9; then
  parts+=("test-gap classification unavailable (graph < 2.3.9)")
fi

[ "${#parts[@]}" -gt 0 ] || exit 0
joined="${parts[0]}"
for p in "${parts[@]:1}"; do joined="${joined}; ${p}"; done
printf -- '- **Graph enrichment degraded:** %s\n' "$joined"
exit 0
