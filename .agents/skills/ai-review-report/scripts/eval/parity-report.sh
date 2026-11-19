#!/bin/bash
# LADR-130: report-only backend parity. Compares two RESULTS lists (kind|id|verdict|detail)
# and prints per-fixture agreement plus verdict counts. Never fails on a difference.
set -euo pipefail

pi_results="$1"; oc_results="$2"
[ -f "$pi_results" ] || { echo "parity: pi results missing: $pi_results"; exit 0; }
[ -f "$oc_results" ] || { echo "parity: opencode results missing: $oc_results"; exit 0; }

echo ""
echo "=========================================="
echo " PARITY: pi vs opencode (report-only)"
echo "=========================================="
printf '%-14s %-30s %-8s %-8s %s\n' "KIND" "FIXTURE" "PI" "OPENCODE" "AGREEMENT"
printf '%-14s %-30s %-8s %-8s %s\n' "----" "-------" "--" "--------" "---------"

agree=0; differ=0
while IFS='|' read -r kind id verdict _detail; do
  [ -n "${id:-}" ] || continue
  oc_verdict="$(awk -F'|' -v id="$id" '$2 == id { print $3; exit }' "$oc_results")"
  [ -n "$oc_verdict" ] || oc_verdict="not-run"
  if [ "$verdict" = "$oc_verdict" ]; then
    printf '%-14s %-30s %-8s %-8s %s\n' "$kind" "$id" "$verdict" "$oc_verdict" "match"
    agree=$((agree + 1))
  else
    printf '%-14s %-30s %-8s %-8s %s\n' "$kind" "$id" "$verdict" "$oc_verdict" "DIFF"
    differ=$((differ + 1))
  fi
done < "$pi_results"

echo ""
echo "Fixtures compared: $((agree + differ)) · match: $agree · differ: $differ"
echo "Precision/recall bars are unchanged; this section is measured, never gated."
exit 0
