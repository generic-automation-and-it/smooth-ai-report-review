#!/bin/bash
# graph-hint-attribution.sh — which graph hint, if any, a reviewer was shown for
# a finding's file, so harvested fp labels can be attributed to the hint class
# that may have induced them (HLD-006 NFR-04). Report-only data.
#
# Usage: graph-hint-attribution.sh <run graph/ dir> <metadata.json> <file> <chunks, comma-separated>
# Prints {"graph_hint":[...],"attribution_unavailable":bool}. Always exits 0.
#
# Source: the run artifact's graph/chunk_<n>_graph_signals.md for each chunk the
# finding names (its `(chunk n)` back-reference). Kinds, from the slice line(s)
# for the finding's file:
#   deleted-symbol  "removed by this PR"
#   coverage        "no test coverage detected by graph" or "reached only through a caller"
#   risk            "— risk <score>"; plus churn when metadata churn_status is "ok"
# A missing graph/ dir, no chunk number, or a named chunk without its slice is
# never guessed: ["none"] with attribution_unavailable true. Slices present but
# no line for the file: ["none"] with attribution_unavailable false.
set -u

dir="${1:-}"; meta="${2:-}"; file="${3:-}"; chunks="${4:-}"

unavailable() { printf '{"graph_hint":["none"],"attribution_unavailable":true}\n'; exit 0; }

[ -n "$dir" ] && [ -d "$dir" ] && [ -n "$file" ] || unavailable
chunks="$(printf '%s' "$chunks" | tr ',' '\n' | grep -E '^[0-9]+$' || true)"
[ -n "$chunks" ] || unavailable

churn=""
[ -n "$meta" ] && [ -s "$meta" ] && churn="$(jq -r '.churn_status // "" | strings' "$meta" 2>/dev/null || true)"

lines=""
for n in $chunks; do
  slice="$dir/chunk_${n}_graph_signals.md"
  [ -s "$slice" ] || unavailable
  lines="${lines}$(grep -F -- "\`${file}:" "$slice" || true)
"
done

kinds=()
printf '%s' "$lines" | grep -q 'removed by this PR' && kinds+=(deleted-symbol)
printf '%s' "$lines" | grep -qE 'no test coverage detected by graph|reached only through a caller' && kinds+=(coverage)
if printf '%s' "$lines" | grep -qE ' — risk [0-9]'; then
  kinds+=(risk)
  [ "$churn" = "ok" ] && kinds+=(churn)
fi
[ "${#kinds[@]}" -gt 0 ] || kinds=(none)
printf '%s\n' "${kinds[@]}" | jq -R . | jq -sc '{graph_hint: ., attribution_unavailable: false}'
exit 0
