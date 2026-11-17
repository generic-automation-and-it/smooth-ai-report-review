#!/usr/bin/env bash
# test-graph-self-review.sh — the report-only self-review measurements
# (HLD-006 NFR-04): S6 and the V5 counters of the graph-data adoption.
#
#   1. eval/measure-skip-recurrence.sh — a known reappearing ai-analyse SKIP is
#      counted from a synthetic timeline pair; `—` files, no-match and multi-
#      match rows land in unmatched_skips; a missing side is "unavailable",
#      never zero.
#   2. eval/lib/graph-hint-attribution.sh — hint kind from the run artifact's
#      per-chunk slice via the finding's chunk back-reference; none +
#      attribution_unavailable when the slice is absent.
#   3. eval/lib/graph-hint-metrics.sh — uptake/accuracy rows and the summary.
#   4. Wiring: the harvester records the fields; run-evals.sh seeds graph data
#      and reports the counters after the verdict.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="${SCRIPT_DIR}/eval"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✅ $1"; pass=$((pass + 1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }

echo "1. skip recurrence"
cat > "$TMP/summary.md" << 'MD'
## ai-analyse auto-fix summary

**Status:** pushed fixes

| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|
| 1. | FIX | Medium | src/a.sh | Quote the variable | mechanical |
| 2. | **SKIP** | Medium | src/a.sh | Retry loop has no backoff. | deferred |
| 3. | SKIP | Low | src/b.sh | Rename helper | intentional |
| 4. | SKIP | Low | src/c.sh | Duplicate   title | ambiguous |
| **R1)** | SKIP | Medium (residual risk) | — | Advisory | advisory |
MD
cat > "$TMP/review.md" << 'MD'
## 🤖 Smooth AI Review — Commit: `abc1234`

## 🔍 Issues Summary

### 🟡 Medium Priority Issues
1. 🟡 [VERIFIED] Medium Priority: Retry   loop has NO backoff — `src/a.sh:40`
   - why

### 🔵 Low Priority
2. 🔵 [VERIFIED] Low Priority: duplicate title — `src/c.sh:3`
   - why
3. 🔵 [VERIFIED] Low Priority: Duplicate title! — `src/c.sh:9`
   - why

## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** comment
MD
out="$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/summary.md" "$TMP/review.md")"
check "status measured" "measured" "$(jq -r .status <<< "$out")"
check "four SKIP rows read (FIX rows ignored)" "4" "$(jq -r .skips <<< "$out")"
check "the known reappearing skip is counted (normalised text, no line in the key)" "1" "$(jq -r .reappeared <<< "$out")"
check "the reappearing row is named" "src/a.sh" "$(jq -r '.reappeared_rows[0].file' <<< "$out")"
check "no-match, multi-match and —-file rows are counted, not dropped" "3" "$(jq -r .unmatched_skips <<< "$out")"
check "skips = reappeared + unmatched (nothing double-counted)" "4" "$(jq -r '.reappeared + .unmatched_skips' <<< "$out")"
check "missing next review → unavailable, never zero" "unavailable" "$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/summary.md" "$TMP/none.md" | jq -r .status)"
check "missing summary → unavailable" "unavailable" "$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/none.md" "$TMP/review.md" | jq -r .status)"
check "unavailable carries no counts" "null" "$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/none.md" "$TMP/review.md" | jq -r .skips)"
printf 'no heading\n' > "$TMP/other.md"
check "a non-summary comment → unavailable" "unavailable" "$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/other.md" "$TMP/review.md" | jq -r .status)"
check "the --pr path does not exec past its EXIT trap (temp dir leak)" "0" \
  "$(grep -c '^  exec bash' "$EVAL/measure-skip-recurrence.sh")"
check "a review without an Issues Summary → unavailable" "unavailable" "$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/summary.md" "$TMP/other.md" | jq -r .status)"

cat > "$TMP/prose-review.md" << 'MD'
## 🔍 Issues Summary

### 🟡 Medium Priority Issues
1. **Retry loop has no backoff** in `src/a.sh:40` — add exponential backoff.

## 🎯 Recommendation
MD
check "an Issues Summary the parser cannot read → unavailable, not a zero" "unavailable" \
  "$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/summary.md" "$TMP/prose-review.md" | jq -r .status)"
cat > "$TMP/clean-review.md" << 'MD'
## 🔍 Issues Summary

### 🟡 Medium Priority Issues
None found

### 🔵 Low Priority
- None found.
- **R1)** 🟡 Residual risk: advisory only — `src/x.sh:1`

## 🎯 Recommendation
MD
out="$(bash "$EVAL/measure-skip-recurrence.sh" "$TMP/summary.md" "$TMP/clean-review.md")"
check "a genuinely clean review is still measured (zero reappeared)" "measured/0" "$(jq -r '"\(.status)/\(.reappeared)"' <<< "$out")"

echo ""
echo "2. hint attribution from the run artifact"
ATTR="$EVAL/lib/graph-hint-attribution.sh"
mkdir -p "$TMP/run/graph"
printf '`src/a.py:10` alpha — risk 0.8 — no test coverage detected by graph\n`src/b.py:5` beta — risk 0.3\n' > "$TMP/run/graph/chunk_1_graph_signals.md"
printf 'Removed symbols the graph still records users for:\n`src/c.py:40` gone — removed by this PR; the graph still records 2 users — verify they were updated or removed.\n' > "$TMP/run/graph/chunk_2_graph_signals.md"
printf '{"churn_status":"ok"}\n' > "$TMP/run/metadata.json"
check "coverage + risk + churn for a covered-gap file" '{"graph_hint":["coverage","risk","churn"],"attribution_unavailable":false}' \
  "$(bash "$ATTR" "$TMP/run/graph" "$TMP/run/metadata.json" src/a.py 1)"
check "deleted-symbol through its chunk back-reference" '{"graph_hint":["deleted-symbol"],"attribution_unavailable":false}' \
  "$(bash "$ATTR" "$TMP/run/graph" "$TMP/run/metadata.json" src/c.py 2)"
check "risk without churn when churn was not ok" '{"graph_hint":["risk"],"attribution_unavailable":false}' \
  "$(bash "$ATTR" "$TMP/run/graph" /dev/null src/b.py 1)"
check "slices present, no line for the file → none, attribution available" '{"graph_hint":["none"],"attribution_unavailable":false}' \
  "$(bash "$ATTR" "$TMP/run/graph" "$TMP/run/metadata.json" src/zzz.py 1)"
check "the chunk's slice absent → none + attribution_unavailable" '{"graph_hint":["none"],"attribution_unavailable":true}' \
  "$(bash "$ATTR" "$TMP/run/graph" "$TMP/run/metadata.json" src/a.py 9)"
check "no graph dir → none + attribution_unavailable" '{"graph_hint":["none"],"attribution_unavailable":true}' \
  "$(bash "$ATTR" "$TMP/nowhere" "$TMP/run/metadata.json" src/a.py 1)"
check "no chunk back-reference → none + attribution_unavailable" '{"graph_hint":["none"],"attribution_unavailable":true}' \
  "$(bash "$ATTR" "$TMP/run/graph" "$TMP/run/metadata.json" src/a.py '')"

echo ""
echo "3. hint uptake and accuracy counters"
MET="$EVAL/lib/graph-hint-metrics.sh"
mkdir -p "$TMP/ci/reviews"
printf '{"id":"MC-X","kind":"must-catch","known_true_positive":{"file":"src/a.py"}}\n' > "$TMP/mc.json"
printf '{"id":"DR-X","kind":"must-not-flag"}\n' > "$TMP/mnf.json"
check "no slice shown → no row" "" "$(bash "$MET" "$TMP/mc.json" "$TMP/ci")"
printf 'x\n' > "$TMP/ci/chunk_0_graph_signals.md"
printf 'review\n' > "$TMP/ci/reviews/chunk_0.md"
cat > "$TMP/ci/reviews/chunk_0.findings.json" << 'JSON'
{"findings":[
 {"file":"src/a.py","severity":"high","graph_evidence":{"query":"test_gaps","target":"alpha","result_summary":"no test coverage"}},
 {"file":"src/b.py","severity":"medium","graph_evidence":{"query":"changed_functions","target":"beta","result_summary":"risk 0.3"}},
 {"file":"src/c.py","severity":"low"}
]}
JSON
check "must-catch row: cited 2, gap claims 1, accepted 1" "$(printf 'MC-X\tmust-catch\t2\t1\t1\t0')" "$(bash "$MET" "$TMP/mc.json" "$TMP/ci")"
check "must-not-flag row: the medium-or-above gap claim is rejected" "$(printf 'DR-X\tmust-not-flag\t2\t1\t0\t1')" "$(bash "$MET" "$TMP/mnf.json" "$TMP/ci")"
mkdir -p "$TMP/hints"
{ bash "$MET" "$TMP/mc.json" "$TMP/ci"; bash "$MET" "$TMP/mc.json" "$TMP/ci"; } > "$TMP/hints/MC-X.tsv"
bash "$MET" "$TMP/mnf.json" "$TMP/ci" > "$TMP/hints/DR-X.tsv"
check "summary line" " Graph hints (report-only): uptake 6 cited finding(s) over 3 sample(s) in 2 fixture(s); test-gap claims 3 — accepted 2, rejected 1" \
  "$(bash "$MET" --summary "$TMP/hints")"
# NFR-04: a missing or malformed sidecar is unavailable, never zero counts.
cp -R "$TMP/ci" "$TMP/ci-missing"; printf 'review\n' > "$TMP/ci-missing/reviews/chunk_1.md"
check "a reviewed chunk without a sidecar → unavailable, not zeros" "$(printf 'MC-X\tmust-catch\tunavailable')" "$(bash "$MET" "$TMP/mc.json" "$TMP/ci-missing")"
cp -R "$TMP/ci" "$TMP/ci-bad"; printf 'not json\n' > "$TMP/ci-bad/reviews/chunk_0.findings.json"
check "a malformed sidecar → unavailable" "$(printf 'MC-X\tmust-catch\tunavailable')" "$(bash "$MET" "$TMP/mc.json" "$TMP/ci-bad")"
cp -R "$TMP/ci-missing" "$TMP/ci-failed"; : > "$TMP/ci-failed/reviews/chunk_1.failed"
check "a failed chunk has no review to measure and is skipped" "$(printf 'MC-X\tmust-catch\t2\t1\t1\t0')" "$(bash "$MET" "$TMP/mc.json" "$TMP/ci-failed")"
bash "$MET" "$TMP/mc.json" "$TMP/ci-missing" >> "$TMP/hints/MC-X.tsv"
check "summary counts unavailable samples apart and keeps them out of the totals" \
  " Graph hints (report-only): uptake 6 cited finding(s) over 3 sample(s) in 2 fixture(s); test-gap claims 3 — accepted 2, rejected 1; 1 sample(s) unavailable (missing or malformed sidecar), excluded" \
  "$(bash "$MET" --summary "$TMP/hints")"
mkdir -p "$TMP/hints-u"; bash "$MET" "$TMP/mc.json" "$TMP/ci-missing" > "$TMP/hints-u/MC-X.tsv"
check "all samples unavailable → the summary says unavailable, never zero" \
  " Graph hints (report-only): unavailable — every sample with a graph hint lacked a usable sidecar; 1 sample(s) unavailable (missing or malformed sidecar), excluded" \
  "$(bash "$MET" --summary "$TMP/hints-u")"
check "summary with nothing shown says so" " Graph hints              : no graph hints shown in any sample (report-only)" \
  "$(bash "$MET" --summary "$TMP/empty-dir")"

echo ""
echo "4. wiring"
check "the harvester records graph_hint and attribution_unavailable" "2" \
  "$(grep -cE '^        (graph_hint: \$hint\.graph_hint|attribution_unavailable: \$hint\.attribution_unavailable),' "$EVAL/harvest-real-findings.sh")"
check "the harvester resolves hints from the artifact's graph/ dir" "1" \
  "$(grep -c 'graph-hint-attribution.sh" "$(dirname "$merged")/graph"' "$EVAL/harvest-real-findings.sh")"
check "run-evals.sh seeds both TSVs and marks the graph available" "3" \
  "$(grep -cE 'cp "\$fdir/graph/graph_(review|removed)_signals.tsv"|export GRAPH_ANALYSIS_AVAILABLE=true' "$EVAL/run-evals.sh")"
metrics_line="$(grep -n 'graph-hint-metrics.sh" --summary' "$EVAL/run-evals.sh" | cut -d: -f1)"
verdict_line="$(grep -n 'EVAL FAILED' "$EVAL/run-evals.sh" | tail -1 | cut -d: -f1)"
check "the counters print after the verdict and cannot change it" "1" \
  "$([ -n "$metrics_line" ] && [ "$metrics_line" -gt "$verdict_line" ] && echo 1 || echo 0)"
check "the deletion-regression recall fixture exists with seeded graph data" "1" \
  "$( [ -s "$EVAL/corpus/must-catch/MC-007-removed-symbol-still-used/graph/graph_removed_signals.tsv" ] \
      && jq -e '.kind == "must-catch" and .min_severity == "HIGH"' "$EVAL/corpus/must-catch/MC-007-removed-symbol-still-used/manifest.json" >/dev/null && echo 1 || echo 0)"

echo ""
echo "=========================================="
echo "Results: ${pass} passed, ${fail} failed"
echo "=========================================="
[ "$fail" -eq 0 ]
