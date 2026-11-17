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
# for the finding's file, read BY SECTION — the slice puts a claim's wording in a
# section heading, so a file listed only under "Changed functions with no test
# coverage detected by graph:" carries the coverage claim without that phrase on
# its own line:
#   deleted-symbol  a row under "Removed symbols the graph still records users for:"
#   coverage        a row under the no-test-coverage heading, or a main row whose
#                   wording says "reached only through a caller"
#   risk            a main row with "— risk <score>"; plus churn when metadata
#                   churn_status is "ok"
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

found=""
for n in $chunks; do
  slice="$dir/chunk_${n}_graph_signals.md"
  [ -s "$slice" ] || unavailable
  found="${found}$(awk -v want="\`${file}:" '
    /^Removed symbols the graph still records users for:$/ { sec = "removed"; next }
    /^Changed functions with no test coverage detected by graph:$/ { sec = "gap"; next }
    index($0, want) != 1 { next }
    sec == "removed" { print "deleted-symbol"; next }
    sec == "gap"     { print "coverage"; next }
    {
      if ($0 ~ /— risk [0-9]/) print "risk"
      if ($0 ~ /reached only through a caller|no test coverage detected by graph/) print "coverage"
    }
  ' "$slice" || true)
"
done

kinds=()
printf '%s' "$found" | grep -qx 'deleted-symbol' && kinds+=(deleted-symbol)
printf '%s' "$found" | grep -qx 'coverage' && kinds+=(coverage)
if printf '%s' "$found" | grep -qx 'risk'; then
  kinds+=(risk)
  [ "$churn" = "ok" ] && kinds+=(churn)
fi
[ "${#kinds[@]}" -gt 0 ] || kinds=(none)
printf '%s\n' "${kinds[@]}" | jq -R . | jq -sc '{graph_hint: ., attribution_unavailable: false}'
exit 0
