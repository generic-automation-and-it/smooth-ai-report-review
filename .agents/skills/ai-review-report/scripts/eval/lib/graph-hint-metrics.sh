#!/bin/bash
# graph-hint-metrics.sh — report-only graph-hint uptake and accuracy for the
# eval harness (HLD-006 NFR-04). Never affects a verdict or exit code.
#
# Per sample:  graph-hint-metrics.sh <manifest.json> <sandbox ci_temp dir>
#   Prints one TSV row — id, kind, cited, gap_claims, accepted, rejected — or
#   nothing when no chunk prompt carried a graph slice (no hint was shown, so
#   there is nothing to take up).
#     cited       findings whose sidecar carries a graph_evidence object
#     gap_claims  cited findings whose graph_evidence names a test/coverage gap
#     accepted    gap claims on the seeded defect's file in a must-catch fixture
#     rejected    gap claims at critical/high/medium in a must-not-flag fixture
# Summary:     graph-hint-metrics.sh --summary <dir of per-fixture .tsv files>
#   Prints one report line, or a "no graph hints shown" line.
set -u

if [ "${1:-}" = "--summary" ]; then
  dir="${2:-}"
  rows="$(cat "$dir"/*.tsv 2>/dev/null | awk -F'\t' 'NF == 6')"
  if [ -z "$rows" ]; then
    echo " Graph hints              : no graph hints shown in any sample (report-only)"
    exit 0
  fi
  printf '%s\n' "$rows" | awk -F'\t' '
    { samples++; fixtures[$1] = 1; cited += $3; gaps += $4; acc += $5; rej += $6 }
    END {
      n = 0; for (f in fixtures) n++
      printf " Graph hints (report-only): uptake %d cited finding(s) over %d sample(s) in %d fixture(s); test-gap claims %d — accepted %d, rejected %d\n", cited, samples, n, gaps, acc, rej
    }'
  exit 0
fi

manifest="${1:-}"
ci="${2:-}"
[ -n "$manifest" ] && [ -f "$manifest" ] && [ -n "$ci" ] && [ -d "$ci" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

shown=0
for slice in "$ci"/chunk_*_graph_signals.md; do
  [ -s "$slice" ] && { shown=1; break; }
done
[ "$shown" = 1 ] || exit 0

id="$(jq -r '.id // "unknown"' "$manifest")"
kind="$(jq -r '.kind // "unknown"' "$manifest")"
tp_file="$(jq -r '.known_true_positive.file // ""' "$manifest")"

cat "$ci"/reviews/chunk_*.findings.json 2>/dev/null \
  | jq -rs --arg id "$id" --arg kind "$kind" --arg tp "$tp_file" '
      [ .[] | (.findings // [])[] ] as $all
      | ($all | map(select((.graph_evidence | type) == "object"))) as $cited
      | ($cited | map(select((.graph_evidence | tostring | ascii_downcase) | test("test|coverage|gap")))) as $gaps
      | [ $id, $kind, ($cited | length), ($gaps | length),
          (if $kind == "must-catch" then ($gaps | map(select(.file == $tp)) | length) else 0 end),
          (if $kind == "must-not-flag" then ($gaps | map(select(.severity == "critical" or .severity == "high" or .severity == "medium")) | length) else 0 end)
        ] | map(tostring) | join("\t")' 2>/dev/null \
  || printf '%s\t%s\t0\t0\t0\t0\n' "$id" "$kind"
exit 0
