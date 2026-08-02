#!/bin/bash
set -e

# Test script for the LADR-055 structured-findings contract:
#   lib/merge-findings.py          — the deterministic merge algorithm
#   lib/merge-findings.sh          — interpreter resolution + sidecar collection
#   lib/extract-findings-json.sh   — sidecar extraction and markdown stripping
#   lib/render-findings-summary.sh — Issues Summary rendering
#
# Offline: no model calls, no network. The renderer tests additionally re-parse
# their own output with the REAL scripts/eval/lib/score-review.sh and
# lib/extract-ai-analyse-scope.sh, so the compatibility claim ("the markdown
# grammar three consumers parse is unchanged") is asserted rather than asserted
# about — if the rendered bullet grammar drifts, these tests fail, not a
# production run three weeks later.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_PY="$SCRIPT_DIR/lib/merge-findings.py"
MERGE_SH="$SCRIPT_DIR/lib/merge-findings.sh"
EXTRACT_SH="$SCRIPT_DIR/lib/extract-findings-json.sh"
RENDER_SH="$SCRIPT_DIR/lib/render-findings-summary.sh"
SCORE_SH="$SCRIPT_DIR/eval/lib/score-review.sh"
ANALYSE_SCOPE_SH="$SCRIPT_DIR/lib/extract-ai-analyse-scope.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=========================================="
echo "Testing merge-findings (LADR-055)"
echo "=========================================="
echo ""

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---"; printf '%s\n' "$actual"
    fail=$((fail + 1))
  fi
}

# Resolve an interpreter the same way merge-findings.sh does; skip cleanly when
# there is none, because Python is a soft dependency by design.
PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
if [ -z "$PY_BIN" ]; then
  echo "⏭️  No Python interpreter available — skipping merge-findings tests"
  echo "    (this mirrors production: an absent interpreter degrades to no merged"
  echo "     document, and the review proceeds on the pre-LADR-055 path)"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "⏭️  jq unavailable — skipping merge-findings tests"
  exit 0
fi

merge() { "$PY_BIN" "$MERGE_PY"; }

# A complete, schema-valid finding, parameterised over the fields the tests vary.
# Keeping one builder means a test that fails is failing on the field it names,
# not on an unrelated typo in a hand-written fixture.
finding() {
  local title="$1" severity="$2" file="$3" line="$4" confidence="$5"
  local pre_existing="$6" first_evidence="$7"
  local fe=""
  [ -n "$first_evidence" ] && fe="\"first_evidence\": \"$first_evidence\","
  cat <<J
{
  "title": "$title",
  "severity": "$severity",
  "file": "$file",
  "line": $line,
  "why_it_matters": "Impact statement for $title.",
  "confidence": $confidence,
  "verified": true,
  "evidence": ["$file:$line -- some code"],
  $fe
  "pre_existing": $pre_existing,
  "requires_verification": false,
  "autofix_class": "gated_auto",
  "owner": "downstream-resolver"
}
J
}

doc() { # doc <chunk> <findings-json-array-body>
  cat <<J
{ "chunk": $1, "findings": [ $2 ], "residual_risks": [], "testing_gaps": [] }
J
}

# --- Test 1: empty input -----------------------------------------------------
out="$(printf '[]' | merge)"; rc=$?
check "Test 1a: empty input exits 0" "0" "$rc"
check "Test 1b: empty input → complete status" "complete" "$(printf '%s' "$out" | jq -r .status)"
check "Test 1c: empty input → no findings" "0" "$(printf '%s' "$out" | jq '.findings | length')"

# --- Test 2: malformed input is counted, never fatal -------------------------
# A non-object document, a document missing `findings`, and a finding with an
# out-of-vocabulary severity — all three must be counted and stepped over.
bad_input='[
  "not an object",
  {"chunk": 0},
  {"chunk": 1, "findings": [{"title":"x","severity":"URGENT","file":"a","line":1,"why_it_matters":"w","confidence":100,"evidence":["e"],"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"human"}], "residual_risks": [], "testing_gaps": []},
  {"chunk": 2, "findings": [{"title":"y","severity":"high","file":"a","line":1,"why_it_matters":"w","confidence":72,"evidence":["e"],"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"human"}], "residual_risks": [], "testing_gaps": []}
]'
out="$(printf '%s' "$bad_input" | merge)"; rc=$?
check "Test 2a: malformed input exits 0" "0" "$rc"
check "Test 2b: two malformed documents counted" "2" "$(printf '%s' "$out" | jq -r .malformed_returns)"
check "Test 2c: bad severity + non-anchor confidence counted" "2" "$(printf '%s' "$out" | jq -r .malformed_findings)"
check "Test 2d: nothing survives" "0" "$(printf '%s' "$out" | jq '.findings | length')"

# --- Test 3: not-an-array stdin ---------------------------------------------
set +e
out="$(printf '{"chunk": 0}' | merge)"; rc=$?
set -e
check "Test 3a: object stdin exits 2" "2" "$rc"
check "Test 3b: object stdin reports failed" "failed" "$(printf '%s' "$out" | jq -r .status)"
set +e
out="$(printf 'not json at all' | merge)"; rc=$?
set -e
check "Test 3c: unparseable stdin exits 2" "2" "$rc"
check "Test 3d: unparseable stdin reports failed" "failed" "$(printf '%s' "$out" | jq -r .status)"

# --- Test 4: cross-chunk dedup ----------------------------------------------
# Same defect, two chunks, differing case and whitespace in the fingerprint
# fields — one merged finding, both chunk numbers recorded.
f_a="$(finding 'Missing ownership guard' critical 'src/A.cs' 42 100 false 'src/A.cs:42 -- q')"
f_b="$(finding 'missing   Ownership  Guard' high 'SRC/A.cs' 42 75 false 'src/A.cs:42 -- q')"
input="[ $(doc 0 "$f_a"), $(doc 3 "$f_b") ]"
out="$(printf '%s' "$input" | merge)"
check "Test 4a: duplicates collapse to one finding" "1" "$(printf '%s' "$out" | jq '.findings | length')"
check "Test 4b: one duplicate counted" "1" "$(printf '%s' "$out" | jq -r .merged_duplicates)"
check "Test 4c: both chunks recorded" "0,3" "$(printf '%s' "$out" | jq -r '.findings[0].chunks | join(",")')"
check "Test 4d: most severe severity wins" "critical" "$(printf '%s' "$out" | jq -r '.findings[0].severity')"
check "Test 4e: stable number assigned" "1" "$(printf '%s' "$out" | jq -r '.findings[0]["#"]')"

# --- Test 5: conservative route merge ---------------------------------------
route_a='{"title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w","confidence":100,"verified":true,"evidence":["e"],"first_evidence":"f:1 -- q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver"}'
route_b='{"title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w","confidence":75,"verified":false,"evidence":["e"],"first_evidence":"f:1 -- q","pre_existing":false,"requires_verification":true,"autofix_class":"advisory","owner":"release"}'
input="[ $(doc 0 "$route_a"), $(doc 1 "$route_b") ]"
out="$(printf '%s' "$input" | merge)"
check "Test 5a: more conservative autofix_class wins" "advisory" "$(printf '%s' "$out" | jq -r '.findings[0].autofix_class')"
check "Test 5b: more conservative owner wins" "release" "$(printf '%s' "$out" | jq -r '.findings[0].owner')"
check "Test 5c: requires_verification ORs to true" "true" "$(printf '%s' "$out" | jq -r '.findings[0].requires_verification')"
check "Test 5d: verified ORs to true" "true" "$(printf '%s' "$out" | jq -r '.findings[0].verified')"

# Severity and confidence merge INDEPENDENTLY. A chunk reporting `high` at 50 and
# another reporting the same defect as `medium` at 100 must merge to high@100 —
# taking the representative's own confidence would give high@50, which the
# confidence gate then suppresses, discarding a contributor who was certain the
# issue is real and merely disagreed about how urgent it is.
axes_severe='{"title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w","confidence":50,"verified":true,"evidence":["e"],"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver"}'
axes_confident='{"title":"t","severity":"medium","file":"f","line":1,"why_it_matters":"w","confidence":100,"verified":true,"evidence":["e"],"first_evidence":"f:1 -- q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver"}'
out="$(printf '[ %s, %s ]' "$(doc 0 "$axes_severe")" "$(doc 1 "$axes_confident")" | merge)"
check "Test 5e: most severe severity wins" "high" "$(printf '%s' "$out" | jq -r '.findings[0].severity')"
check "Test 5f: highest confidence wins, independently of severity" "100" \
  "$(printf '%s' "$out" | jq -r '.findings[0].confidence')"
check "Test 5g: merged finding survives the gate" "1" "$(printf '%s' "$out" | jq '.findings | length')"

# ...but a raised confidence with no quote ANYWHERE in the group is demoted back.
axes_noquote='{"title":"t","severity":"medium","file":"f","line":1,"why_it_matters":"w","confidence":100,"verified":true,"evidence":["e"],"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver"}'
out="$(printf '[ %s, %s ]' "$(doc 0 "$axes_severe")" "$(doc 1 "$axes_noquote")" | merge)"
check "Test 5h: raised confidence with no quote in the group is demoted" "50" \
  "$(printf '%s' "$out" | jq -r '.suppressed_findings[0].confidence')"

# --- Test 6: quote-the-line gate --------------------------------------------
f_noquote="$(finding 'Unquoted claim' high 'src/C.cs' 9 75 false '')"
out="$(printf '[ %s ]' "$(doc 0 "$f_noquote")" | merge)"
check "Test 6a: 75 without first_evidence is demoted to 50" "50" \
  "$(printf '%s' "$out" | jq -r '.suppressed_findings[0].confidence')"
check "Test 6b: demotion counted" "1" "$(printf '%s' "$out" | jq -r .demoted_no_quote)"
check "Test 6c: demoted finding is marked" "true" \
  "$(printf '%s' "$out" | jq -r '.suppressed_findings[0].demoted_no_quote')"

f_quoted="$(finding 'Quoted claim' high 'src/C.cs' 9 75 false 'src/C.cs:9 -- q')"
out="$(printf '[ %s ]' "$(doc 0 "$f_quoted")" | merge)"
check "Test 6d: 75 WITH first_evidence survives at 75" "75" \
  "$(printf '%s' "$out" | jq -r '.findings[0].confidence')"
check "Test 6e: nothing demoted" "0" "$(printf '%s' "$out" | jq -r .demoted_no_quote)"

# --- Test 7: confidence gate -------------------------------------------------
f_med50="$(finding 'Nitpick' medium 'src/B.cs' 7 50 false '')"
out="$(printf '[ %s ]' "$(doc 0 "$f_med50")" | merge)"
check "Test 7a: medium at 50 is suppressed" "0" "$(printf '%s' "$out" | jq '.findings | length')"
check "Test 7b: suppressed finding recorded" "1" "$(printf '%s' "$out" | jq '.suppressed_findings | length')"
check "Test 7c: suppression counted per anchor" "1" \
  "$(printf '%s' "$out" | jq -r '.suppressed_by_confidence["50"]')"

# The critical escape: an important-but-uncertain blocker must never vanish.
f_crit50="$(finding 'Uncertain blocker' critical 'src/D.cs' 3 50 false '')"
out="$(printf '[ %s ]' "$(doc 0 "$f_crit50")" | merge)"
check "Test 7d: critical at 50 SURVIVES the gate" "1" "$(printf '%s' "$out" | jq '.findings | length')"
check "Test 7e: critical at 50 is not suppressed" "0" \
  "$(printf '%s' "$out" | jq '.suppressed_findings | length')"

# --- Test 8: pre_existing disagreement --------------------------------------
pe_true="$(finding 'Shared defect' high 'src/E.cs' 5 100 true 'src/E.cs:5 -- q')"
pe_false="$(finding 'Shared defect' high 'src/E.cs' 5 100 false 'src/E.cs:5 -- q')"
input="[ $(doc 0 "$pe_true"), $(doc 1 "$pe_false") ]"
out="$(printf '%s' "$input" | merge)"
check "Test 8a: pre_existing disagreement resolves to false" "false" \
  "$(printf '%s' "$out" | jq -r '.findings[0].pre_existing')"
check "Test 8b: finding is actionable, not filed as pre-existing" "0" \
  "$(printf '%s' "$out" | jq '.pre_existing_findings | length')"

input="[ $(doc 0 "$pe_true"), $(doc 1 "$pe_true") ]"
out="$(printf '%s' "$input" | merge)"
check "Test 8c: unanimous pre_existing is partitioned out" "1" \
  "$(printf '%s' "$out" | jq '.pre_existing_findings | length')"
check "Test 8d: unanimous pre_existing is not actionable" "0" \
  "$(printf '%s' "$out" | jq '.findings | length')"

# --- Test 9: determinism -----------------------------------------------------
# Same input twice → byte-identical output, including `#` assignment. The eval
# harness and any future run-to-run diff depend on this.
multi="[ $(doc 0 "$(finding 'Zeta issue' high 'src/z.cs' 2 100 false 'q')"),
         $(doc 1 "$(finding 'Alpha issue' high 'src/a.cs' 8 100 false 'q')"),
         $(doc 2 "$(finding 'Beta issue' critical 'src/b.cs' 1 75 false 'q')") ]"
out1="$(printf '%s' "$multi" | merge)"
out2="$(printf '%s' "$multi" | merge)"
check "Test 9a: identical input → byte-identical output" "$out1" "$out2"
check "Test 9b: sort is severity-first" "Beta issue" "$(printf '%s' "$out1" | jq -r '.findings[0].title')"
check "Test 9c: ties break on file path" "Alpha issue" "$(printf '%s' "$out1" | jq -r '.findings[1].title')"
check "Test 9d: numbering is 1-based and dense" "1,2,3" \
  "$(printf '%s' "$out1" | jq -r '[.findings[]["#"]] | join(",")')"

# --- Test 10: sidecar extraction + markdown stripping ------------------------
work="$TMP_DIR/reviews"
mkdir -p "$work"
body='### 📄 File: `src/A.cs`

**Issues Found:**
- 🔴 [VERIFIED] Critical: Missing ownership guard'

{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '{"chunk": 99, "findings": [], "residual_risks": ["r"], "testing_gaps": []}\n'
  printf '```\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_2.md"

bash "$EXTRACT_SH" "$work/chunk_2.md" 2 "$work/chunk_2.findings.json" >/dev/null
check "Test 10a: sidecar extracted" "true" \
  "$([ -s "$work/chunk_2.findings.json" ] && echo true || echo false)"
check "Test 10b: chunk number stamped from filename, not the model" "2" \
  "$(jq -r .chunk "$work/chunk_2.findings.json")"
check "Test 10c: sentinel block stripped from markdown" "$body" "$(cat "$work/chunk_2.md")"
check "Test 10d: no sentinel leaks into the posted body" "0" \
  "$(grep -c 'FINDINGS_JSON' "$work/chunk_2.md" || true)"

# A chunk whose model omitted the block must be byte-identical to before.
printf '%s\n' "$body" > "$work/chunk_5.md"
cp "$work/chunk_5.md" "$TMP_DIR/chunk_5.before.md"
bash "$EXTRACT_SH" "$work/chunk_5.md" 5 "$work/chunk_5.findings.json" >/dev/null
check "Test 10e: no sidecar → markdown byte-identical" "$(cat "$TMP_DIR/chunk_5.before.md")" "$(cat "$work/chunk_5.md")"
check "Test 10f: no sidecar → no output file" "false" \
  "$([ -f "$work/chunk_5.findings.json" ] && echo true || echo false)"

# Malformed JSON still strips (a wall of broken JSON must never reach the PR)
# and must NOT create a chunk-failure flag — LADR-031 owns that channel.
{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n{ not json\n```\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_6.md"
bash "$EXTRACT_SH" "$work/chunk_6.md" 6 "$work/chunk_6.findings.json" >/dev/null
check "Test 10g: malformed sidecar still stripped" "$body" "$(cat "$work/chunk_6.md")"
check "Test 10h: malformed sidecar produces no output file" "false" \
  "$([ -f "$work/chunk_6.findings.json" ] && echo true || echo false)"
check "Test 10i: extraction never writes a .failed flag (LADR-031)" "0" \
  "$(ls "$work"/*.failed 2>/dev/null | wc -l | tr -d ' ')"

# --- Test 11: wrapper collection --------------------------------------------
rm -f "$work"/*.findings.json
printf '%s' "$(doc 0 "$(finding 'Wrapper A' critical 'src/A.cs' 1 100 false 'q')")" > "$work/chunk_0.findings.json"
printf '%s' "$(doc 1 "$(finding 'Wrapper B' medium 'src/B.cs' 2 100 false 'q')")" > "$work/chunk_1.findings.json"
printf 'not json' > "$work/chunk_2.findings.json"
bash "$MERGE_SH" "$work" "$TMP_DIR/merged.json" >/dev/null 2>&1
check "Test 11a: wrapper wrote a merged document" "complete" "$(jq -r .status "$TMP_DIR/merged.json")"
check "Test 11b: unparseable sidecar skipped, valid ones kept" "2" \
  "$(jq '.findings | length' "$TMP_DIR/merged.json")"

set +e
bash "$MERGE_SH" "$TMP_DIR/no-such-dir" "$TMP_DIR/none.json" >/dev/null 2>&1; rc=$?
set -e
check "Test 11c: missing reviews dir exits 1, writes nothing" "1" "$rc"
check "Test 11d: no merged document written" "false" \
  "$([ -f "$TMP_DIR/none.json" ] && echo true || echo false)"

# --- Test 12: rendered grammar is what the consumers parse -------------------
rendered="$TMP_DIR/rendered.md"
bash "$RENDER_SH" "$TMP_DIR/merged.json" > "$rendered"

check "Test 12a: Issues Summary header present (artifact identification)" "1" \
  "$(grep -c '^## 🔍 Issues Summary$' "$rendered")"
for header in '### 🔴 Critical Issues' '### 🟠 High Priority Issues' \
              '### 🟡 Medium Priority Issues' '### 🔵 Low Priority / Nitpicks'; do
  check "Test 12b: header preserved — $header" "1" "$(grep -cF "$header" "$rendered")"
done

# score-review.sh is the eval scorer's grammar parser. Run the real one.
if [ -x "$SCORE_SH" ]; then
  scored="$(bash "$SCORE_SH" "$rendered" | tr '\n' ',' | sed 's/,$//')"
  check "Test 12c: score-review.sh reads the rendered grammar" "CRITICAL,MEDIUM" "$scored"
else
  echo "⏭️  score-review.sh not executable — skipping grammar cross-check"
fi

# extract-ai-analyse-scope.sh drives the autonomous fixer off the Medium section.
if [ -x "$ANALYSE_SCOPE_SH" ]; then
  scope="$(bash "$ANALYSE_SCOPE_SH" "$rendered")"
  check "Test 12d: ai-analyse still sees actionable low/medium scope" "true" \
    "$(printf '%s' "$scope" | jq -r .has_low_medium)"
  check "Test 12e: ai-analyse Medium section is non-empty" "true" \
    "$(printf '%s' "$scope" | jq -r '.medium | test("Wrapper B")')"
else
  echo "⏭️  extract-ai-analyse-scope.sh not executable — skipping scope cross-check"
fi

# The Coverage block must always render, including when every count is zero —
# suppression nobody can see is suppression nobody should trust.
out="$(printf '[]' | merge)"
printf '%s' "$out" > "$TMP_DIR/empty-merged.json"
bash "$RENDER_SH" "$TMP_DIR/empty-merged.json" > "$TMP_DIR/empty-rendered.md"
check "Test 12f: Coverage block renders even when empty" "1" \
  "$(grep -c '^### 📊 Coverage$' "$TMP_DIR/empty-rendered.md")"
check "Test 12g: empty summary uses the None found placeholder" "4" \
  "$(grep -c '^None found$' "$TMP_DIR/empty-rendered.md")"

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ]
