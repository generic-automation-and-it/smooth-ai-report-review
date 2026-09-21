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
# SUITE_COMPLETED is flipped to 1 on the last line. Without this, a `set -e`
# abort mid-suite exits non-zero but prints a screen full of ✅ and no summary,
# which reads exactly like a pass to anyone skimming (that is how the Test 17d
# brace-expansion abort hid Tests 18-25 from every run for two releases).
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$TMP_DIR"; if [ "$SUITE_COMPLETED" != "1" ]; then echo ""; echo "❌ SUITE ABORTED EARLY (exit $rc) — assertions after this point never ran"; fi' EXIT

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

# LADR-063: pre-existing items are numbered too, in their own `#P` sequence.
# They are reported and never counted toward the verdict, so they must not draw
# from the findings sequence — but an unnumbered item cannot be referenced in a
# skip decision, which is the whole reason the section exists.
printf '%s' "$out" > "$TMP_DIR/pe-merged.json"
bash "$RENDER_SH" "$TMP_DIR/pe-merged.json" > "$TMP_DIR/pe-rendered.md"
pe_section="$(awk '/^### 🗂️ Pre-existing/{c=1;next} c&&/^### /{exit} c' "$TMP_DIR/pe-rendered.md")"
check "Test 8e: pre-existing items are numbered P1)..Pn)" "1" \
  "$(printf '%s\n' "$pe_section" | grep -cE '^- \*\*P[0-9]+\)\*\* ' || true)"
check "Test 8f: pre-existing numbering does not use the findings namespace" "0" \
  "$(printf '%s\n' "$pe_section" | grep -cE '^[0-9]+\. ' || true)"
if [ -x "$SCORE_SH" ]; then
  check "Test 8g: numbering a pre-existing item does not make it a flag" "" \
    "$(bash "$SCORE_SH" "$TMP_DIR/pe-rendered.md" | tr '\n' ',' | sed 's/,$//')"
fi

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

# A review that QUOTES a sentinel must not lose the prose after it. Six of this
# repo's own tracked files contain the literal sentinel and the review model is
# told to quote the code it flags, so this is the canonical self-review case, not
# a hypothetical. Anchoring on the first `begin` truncated the review here, took
# the real sidecar with it, and could drop the body under the 200-byte
# empty-output floor — turning a clean chunk into a fail-closed REQUEST_CHANGES.
quoted_body='**Issues Found:**
- 🟠 [VERIFIED] High Priority: the extractor keys on `<!-- FINDINGS_JSON_BEGIN -->` in review text.
- 🟡 [VERIFIED] Medium Priority: this finding is after the quote and must survive.'
{
  printf '%s\n\n' "$quoted_body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '{"chunk": 99, "findings": [], "residual_risks": [], "testing_gaps": []}\n'
  printf '```\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_7.md"
bash "$EXTRACT_SH" "$work/chunk_7.md" 7 "$work/chunk_7.findings.json" >/dev/null
check "Test 10j: quoted sentinel does not truncate the review" "$quoted_body" "$(cat "$work/chunk_7.md")"
check "Test 10k: real sidecar still extracted past a quoted sentinel" "7" \
  "$(jq -r .chunk "$work/chunk_7.findings.json" 2>/dev/null || echo missing)"

# A quoted sentinel with no closing one is indistinguishable from a truncated
# block. Strip nothing: a fenced JSON block left in the body is cosmetic, losing
# the rest of the review is not.
printf '%s\n' "$quoted_body" > "$work/chunk_8.md"
cp "$work/chunk_8.md" "$TMP_DIR/chunk_8.before.md"
bash "$EXTRACT_SH" "$work/chunk_8.md" 8 "$work/chunk_8.findings.json" >/dev/null
check "Test 10l: unterminated sentinel leaves the body untouched" \
  "$(cat "$TMP_DIR/chunk_8.before.md")" "$(cat "$work/chunk_8.md")"
check "Test 10m: unterminated sentinel produces no sidecar" "false" \
  "$([ -f "$work/chunk_8.findings.json" ] && echo true || echo false)"

# A quoted COMPLETE pair (the docs example) followed by the real block: the last
# complete pair is the sidecar, the quoted one is prose and stays.
{
  printf 'The gate emits:\n<!-- FINDINGS_JSON_BEGIN -->\nexample\n<!-- FINDINGS_JSON_END -->\n'
  printf -- '- 🟠 [VERIFIED] High Priority: real finding after the quoted example.\n\n'
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '{"chunk": 99, "findings": [], "residual_risks": [], "testing_gaps": []}\n'
  printf '```\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_9.md"
bash "$EXTRACT_SH" "$work/chunk_9.md" 9 "$work/chunk_9.findings.json" >/dev/null
check "Test 10n: quoted complete pair survives, last pair is the sidecar" "1" \
  "$(grep -c 'FINDINGS_JSON_BEGIN' "$work/chunk_9.md" || true)"
check "Test 10o: real finding after the quoted example survives" "1" \
  "$(grep -c 'real finding after the quoted example' "$work/chunk_9.md" || true)"
check "Test 10o1: a clean extraction leaves no rejected-payload file" "false" \
  "$([ -f "$work/chunk_9.findings.rejected.txt" ] && echo true || echo false)"
# Both remaining shapes below were produced by one real MiniMax M3 review of this
# repo's own LADR-055 diff — the truncated block and the inline quote appeared in
# the same run. A delimiter is alone on its line; an unterminated one is honoured
# only when what follows looks like the block.
{
  printf -- '- 🟡 [VERIFIED] Medium Priority: prose that must survive.\n\n'
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n{\n  "chunk": 2,\n  "findings": [\n    { "owner": "human",\n'
} > "$work/chunk_10.md"
bash "$EXTRACT_SH" "$work/chunk_10.md" 10 "$work/chunk_10.findings.json" >/dev/null
check "Test 10p: truncated mid-block sidecar is stripped to EOF" "0" \
  "$(grep -c 'FINDINGS_JSON' "$work/chunk_10.md" || true)"
check "Test 10q: prose before a truncated block survives" "1" \
  "$(grep -c 'prose that must survive' "$work/chunk_10.md" || true)"

# LADR-077: a reject keeps its evidence. Rejecting silently made the most common
# LADR-064 failure undiagnosable — "truncated mid-block" could equally mean the
# model was cut off or that it closed the block in a shape the anchoring awk does
# not accept, and the uploaded artifact could not tell them apart.
check "Test 10q1: a rejected sidecar leaves its payload beside the chunk" "true" \
  "$([ -f "$work/chunk_10.findings.rejected.txt" ] && echo true || echo false)"
check "Test 10q2: the rejected payload carries the block that failed to parse" "1" \
  "$(grep -c '"chunk": 2' "$work/chunk_10.findings.rejected.txt" || true)"
check "Test 10q3: the rejected payload names the sentinel state" "1" \
  "$(grep -c 'unterminated begin, stripped to EOF' "$work/chunk_10.findings.rejected.txt" || true)"
check "Test 10q4: the rejected file is outside the merge glob" "0" \
  "$(find "$work" -maxdepth 1 -name 'chunk_*.findings.json' -newer "$work/chunk_10.md" | grep -c 'chunk_10' || true)"

printf -- '- 🟠 High: the extractor keys on `<!-- FINDINGS_JSON_BEGIN -->` inline in prose.\nTAIL\n' \
  > "$work/chunk_11.md"
cp "$work/chunk_11.md" "$TMP_DIR/chunk_11.before.md"
bash "$EXTRACT_SH" "$work/chunk_11.md" 11 "$work/chunk_11.findings.json" >/dev/null
check "Test 10r: sentinel quoted INLINE is not a delimiter" \
  "$(cat "$TMP_DIR/chunk_11.before.md")" "$(cat "$work/chunk_11.md")"

printf 'Docs say:\n<!-- FINDINGS_JSON_BEGIN -->\nProse explaining the block, not JSON.\nTAIL\n' \
  > "$work/chunk_12.md"
cp "$work/chunk_12.md" "$TMP_DIR/chunk_12.before.md"
bash "$EXTRACT_SH" "$work/chunk_12.md" 12 "$work/chunk_12.findings.json" >/dev/null
check "Test 10s: unterminated sentinel followed by prose is left alone" \
  "$(cat "$TMP_DIR/chunk_12.before.md")" "$(cat "$work/chunk_12.md")"

# LADR-079: glm-5.2 mangles `-->` on the closer (run 34764534601, 3/3 chunks).
# JSON is complete; only the HTML-comment terminator is malformed. Prefix-match
# the END line and peel any leftover trailing `<!--` so jq sees a document.
# BEGIN stays exact. Replay the two observed shapes plus the diagnostic split
# LADR-077 wanted: "truncated" vs "mangled sentinel".
_ladr079_json_2='{"chunk":0,"findings":[{},{}],"residual_risks":[],"testing_gaps":[]}'
_ladr079_json_3='{"chunk":1,"findings":[{},{},{}],"residual_risks":[],"testing_gaps":[]}'

{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '%s\n' "$_ladr079_json_2"
  printf '```\n<!-- FINDINGS_JSON_END>\n'
} > "$work/chunk_13.md"
_log13="$(bash "$EXTRACT_SH" "$work/chunk_13.md" 13 "$work/chunk_13.findings.json" 2>&1)"
check "Test 10t: mangled END \`>\` still extracts the sidecar" "2" \
  "$(jq '.findings | length' "$work/chunk_13.findings.json" 2>/dev/null || echo missing)"
check "Test 10t2: mangled END \`>\` still strips the sentinel range" "$body" \
  "$(cat "$work/chunk_13.md")"
check "Test 10t3: mangled END \`>\` does not log truncated mid-block" "0" \
  "$(printf '%s\n' "$_log13" | grep -c 'truncated mid-block' || true)"
check "Test 10t4: mangled END \`>\` leaves no rejected-payload file" "false" \
  "$([ -f "$work/chunk_13.findings.rejected.txt" ] && echo true || echo false)"
check "Test 10t5: mangled END \`>\` never writes a .failed flag" "0" \
  "$(ls "$work"/*.failed 2>/dev/null | wc -l | tr -d ' ')"

{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '%s\n' "$_ladr079_json_3"
  printf '```\n<!-- FINDINGS_JSON_END →\n'
} > "$work/chunk_14.md"
_log14="$(bash "$EXTRACT_SH" "$work/chunk_14.md" 14 "$work/chunk_14.findings.json" 2>&1)"
check "Test 10u: mangled END U+2192 still extracts the sidecar" "3" \
  "$(jq '.findings | length' "$work/chunk_14.findings.json" 2>/dev/null || echo missing)"
check "Test 10u2: mangled END U+2192 still strips the sentinel range" "$body" \
  "$(cat "$work/chunk_14.md")"
check "Test 10u3: mangled END U+2192 does not log truncated mid-block" "0" \
  "$(printf '%s\n' "$_log14" | grep -c 'truncated mid-block' || true)"
check "Test 10u4: mangled END U+2192 writes no rejected-payload file" "false" \
  "$([ -f "$work/chunk_14.findings.rejected.txt" ] && echo true || echo false)"

# Genuine truncation — JSON cut mid-object, no END-ish line — stays rejected,
# stripped to EOF, and still uses the LADR-064 "truncated mid-block" wording.
{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n{\n  "chunk": 15,\n  "findings": [\n    { "owner": "human",\n'
} > "$work/chunk_15.md"
_log15="$(bash "$EXTRACT_SH" "$work/chunk_15.md" 15 "$work/chunk_15.findings.json" 2>&1)"
check "Test 10v: genuine truncation still logs truncated mid-block" "1" \
  "$(printf '%s\n' "$_log15" | grep -c 'truncated mid-block' || true)"
check "Test 10v2: genuine truncation still writes rejected.txt" "true" \
  "$([ -f "$work/chunk_15.findings.rejected.txt" ] && echo true || echo false)"
check "Test 10v3: genuine truncation rejected.txt keeps unterminated state" "1" \
  "$(grep -c 'unterminated begin, stripped to EOF' "$work/chunk_15.findings.rejected.txt" || true)"
check "Test 10v4: genuine truncation still strips to EOF" "0" \
  "$(grep -c 'FINDINGS_JSON' "$work/chunk_15.md" || true)"
check "Test 10v5: genuine truncation prose before the block survives" "1" \
  "$(grep -c 'Missing ownership guard' "$work/chunk_15.md" || true)"
check "Test 10v6: genuine truncation produces no sidecar" "false" \
  "$([ -f "$work/chunk_15.findings.json" ] && echo true || echo false)"

# Truncation that happens to end on an END-prefixed garbage line is "complete"
# by prefix then fails jq — same reject path, but the diagnostic must not say
# truncated. That is the split LADR-077's rejected.txt exists to make.
{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n{\n  "chunk": 16,\n  "findings": [\n'
  printf '<!-- FINDINGS_JSON_END>\n'
} > "$work/chunk_16.md"
_log16="$(bash "$EXTRACT_SH" "$work/chunk_16.md" 16 "$work/chunk_16.findings.json" 2>&1)"
check "Test 10w: prefix-closed truncated JSON does not log truncated mid-block" "0" \
  "$(printf '%s\n' "$_log16" | grep -c 'truncated mid-block' || true)"
check "Test 10w2: prefix-closed truncated JSON names the malformed sentinel" "1" \
  "$(printf '%s\n' "$_log16" | grep -c 'end sentinel present but malformed' || true)"
check "Test 10w3: prefix-closed truncated JSON rejected.txt names prefix state" "1" \
  "$(grep -c 'sentinel range:.*end sentinel present but malformed (matched by prefix)' "$work/chunk_16.findings.rejected.txt" || true)"
check "Test 10w4: prefix-closed truncated JSON still produces no sidecar" "false" \
  "$([ -f "$work/chunk_16.findings.json" ] && echo true || echo false)"

# Inline mid-sentence END mention is prose, never a delimiter — even the
# mangled glm-5.2 shape. Quote lives in the review body; the real block follows.
_end_quoted_body="${body}
- 🟠 High: the closer keys on \`<!-- FINDINGS_JSON_END>\` inline in prose."
{
  printf '%s\n\n' "$_end_quoted_body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '%s\n' "$_ladr079_json_2"
  printf '```\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_17.md"
bash "$EXTRACT_SH" "$work/chunk_17.md" 17 "$work/chunk_17.findings.json" >/dev/null
check "Test 10x: inline END quote does not terminate a block" "2" \
  "$(jq '.findings | length' "$work/chunk_17.findings.json" 2>/dev/null || echo missing)"
check "Test 10x2: inline END quote survives in the posted body" "$_end_quoted_body" \
  "$(cat "$work/chunk_17.md")"
unset _end_quoted_body

# Self-review: a fenced, alone-on-a-line quoted sentinel (this PR quotes the
# mangled closer in a code fence). Fence-unaware awk treats that line as a
# delimiter IF a BEGIN is already open; quoted before the real block it is
# inert because cand is unset. Pin: prose after the quote survives, and the
# real sidecar still extracts. Worst case allowed = this chunk's sidecar lost;
# losing the prose after the quote is not.
{
  printf '%s\n\n' "$body"
  printf 'The closer glm-5.2 emitted:\n```\n<!-- FINDINGS_JSON_END →\n```\n'
  printf 'TAIL PROSE AFTER THE QUOTE MUST SURVIVE.\n\n'
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '%s\n' "$_ladr079_json_3"
  printf '```\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_18.md"
bash "$EXTRACT_SH" "$work/chunk_18.md" 18 "$work/chunk_18.findings.json" >/dev/null
check "Test 10y: fenced quoted mangled END does not swallow following prose" "1" \
  "$(grep -c 'TAIL PROSE AFTER THE QUOTE MUST SURVIVE' "$work/chunk_18.md" || true)"
check "Test 10y2: real sidecar still extracted past a fenced quoted END" "3" \
  "$(jq '.findings | length' "$work/chunk_18.findings.json" 2>/dev/null || echo missing)"
check "Test 10y3: quoted closer remains visible in the body" "1" \
  "$(grep -c 'FINDINGS_JSON_END' "$work/chunk_18.md" || true)"

# Belt: trailing `<!--` lines inside a well-closed block are dropped before jq,
# last-lines-only. A comment after the JSON but before END is not JSON.
{
  printf '%s\n\n' "$body"
  printf '<!-- FINDINGS_JSON_BEGIN -->\n```json\n'
  printf '%s\n' "$_ladr079_json_2"
  printf '```\n<!-- leftover after the fence -->\n<!-- FINDINGS_JSON_END -->\n'
} > "$work/chunk_19.md"
bash "$EXTRACT_SH" "$work/chunk_19.md" 19 "$work/chunk_19.findings.json" >/dev/null
check "Test 10z: trailing HTML-comment lines are peeled before jq" "2" \
  "$(jq '.findings | length' "$work/chunk_19.findings.json" 2>/dev/null || echo missing)"

rm -f "$work"/chunk_{7,8,9,10,11,12,13,14,15,16,17,18,19}.md \
      "$work"/chunk_{7,8,9,10,11,12,13,14,15,16,17,18,19}.findings.json \
      "$work"/chunk_{7,8,9,10,11,12,13,14,15,16,17,18,19}.findings.rejected.txt
unset _ladr079_json_2 _ladr079_json_3 _log13 _log14 _log15 _log16

# --- Test 11: wrapper collection --------------------------------------------
rm -f "$work"/*.findings.json
printf '%s' "$(doc 0 "$(finding 'Wrapper A' critical 'src/A.cs' 1 100 false 'q')")" > "$work/chunk_0.findings.json"
printf '%s' "$(doc 1 "$(finding 'Wrapper B' medium 'src/B.cs' 2 100 false 'q')")" > "$work/chunk_1.findings.json"
printf 'not json' > "$work/chunk_2.findings.json"
bash "$MERGE_SH" "$work" "$TMP_DIR/merged.json" >/dev/null 2>&1
check "Test 11a: wrapper wrote a merged document" "complete" "$(jq -r .status "$TMP_DIR/merged.json")"
check "Test 11b: unparseable sidecar skipped, valid ones kept" "2" \
  "$(jq '.findings | length' "$TMP_DIR/merged.json")"
# Coverage must be counted from what the merge ingested, not from files on disk.
# Three sidecars exist here and one was rejected: an `ls`-based count would read
# 3, satisfy aggregation's full-coverage precondition, and render a summary
# missing chunk 2 while reporting complete coverage.
check "Test 11b2: merged_chunks names only the ingested chunks" "0,1" \
  "$(jq -r '.merged_chunks | join(",")' "$TMP_DIR/merged.json")"
check "Test 11b3: merged_chunks is shorter than the sidecar file count" "3" \
  "$(ls "$work"/chunk_*.findings.json 2>/dev/null | wc -l | tr -d ' ')"

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

# --- Test 13: soft buckets render into the Medium tier ------------------------
# Residual risks and testing gaps are real work the reviewer identified. They are
# rendered as Medium bullets so a reader and `ai-analyse` both see them — but
# WITHOUT the [VERIFIED] tag, because score-review.sh counts a flag only when the
# label carries both the tag and a severity keyword, and DR precision is
# zero-tolerance. An honest "no test covers the new branch" note must never fail
# a must-not-flag fixture.
soft_in='[
  {"chunk":0,"findings":[],"residual_risks":["No rate limiting on export"],
   "testing_gaps":["No test covers the new guard","No test for concurrency"]},
  {"chunk":1,"findings":[],"residual_risks":["  no   RATE limiting on export "],
   "testing_gaps":["No test covers the new guard"]}
]'
soft_out="$(printf '%s' "$soft_in" | merge)"
check "Test 13a: testing gaps deduplicated across chunks" "2" \
  "$(printf '%s' "$soft_out" | jq '.testing_gaps | length')"
check "Test 13b: residual risks deduplicated case/whitespace-insensitively" "1" \
  "$(printf '%s' "$soft_out" | jq '.residual_risks | length')"
check "Test 13c: first-seen wording wins (deterministic)" "No rate limiting on export" \
  "$(printf '%s' "$soft_out" | jq -r '.residual_risks[0]')"

printf '%s' "$soft_out" > "$TMP_DIR/soft-merged.json"
bash "$RENDER_SH" "$TMP_DIR/soft-merged.json" > "$TMP_DIR/soft-rendered.md"
soft_medium="$(awk '/^### 🟡 Medium Priority Issues$/{c=1;next} c&&/^### /{exit} c' "$TMP_DIR/soft-rendered.md")"
check "Test 13d: testing gaps render in the Medium section" "2" \
  "$(printf '%s\n' "$soft_medium" | grep -c 'Testing gap:' || true)"
check "Test 13e: residual risks render in the Medium section" "1" \
  "$(printf '%s\n' "$soft_medium" | grep -c 'Residual risk:' || true)"
check "Test 13f: soft bullets carry no [VERIFIED] tag" "0" \
  "$(printf '%s\n' "$soft_medium" | grep -c 'VERIFIED' || true)"
check "Test 13g: Medium section is not None found when only soft items exist" "0" \
  "$(printf '%s\n' "$soft_medium" | grep -c '^None found$' || true)"

# LADR-063: soft items are numbered in their OWN sequences (#T1…, #R1…), not in
# the findings' #N sequence. Two separate contracts are pinned here. First, they
# ARE numbered — an unnumbered item cannot be referenced in a fix/skip decision,
# which is what made residual risks invisible in practice. Second, the sequences
# are independent: adding a finding must not repoint `#R1`, because the PR
# description's Skip Areas bullets are read by the NEXT run's gate and a shifted
# number silently rebinds a skip to a different item.
check "Test 13j: testing gaps are numbered T1)..Tn)" "2" \
  "$(printf '%s\n' "$soft_medium" | grep -cE '^- \*\*T[0-9]+\)\*\* ' || true)"
check "Test 13k: residual risks are numbered R1)..Rn)" "1" \
  "$(printf '%s\n' "$soft_medium" | grep -cE '^- \*\*R[0-9]+\)\*\* ' || true)"
check "Test 13l: each soft sequence starts at 1 (independent of findings)" "1,1" \
  "$(printf '%s\n' "$soft_medium" | grep -oE '\b[TR]1\)' | sed 's/[TR]//;s/)//' | tr '\n' ',' | sed 's/,$//')"
check "Test 13m: soft numbers never collide with the findings namespace" "0" \
  "$(printf '%s\n' "$soft_medium" | grep -cE '^[0-9]+\. ' || true)"

if [ -x "$SCORE_SH" ]; then
  check "Test 13h: soft items alone are NOT scored as a flag (DR precision)" "" \
    "$(bash "$SCORE_SH" "$TMP_DIR/soft-rendered.md" | tr '\n' ',' | sed 's/,$//')"
fi
if [ -x "$ANALYSE_SCOPE_SH" ]; then
  check "Test 13i: ai-analyse sees soft items as actionable scope" "true" \
    "$(bash "$ANALYSE_SCOPE_SH" "$TMP_DIR/soft-rendered.md" | jq -r .has_low_medium)"
fi

# --- Test 14: the Issues Summary always has a home ---------------------------
# Requiring an existing `## 🔍 Issues Summary` to replace was a real defect: when
# the orchestrator's own summary call fails, aggregate-reviews.sh substitutes a
# fallback template with no such heading, and a healthy merged document was
# silently discarded. Observed on PR #106 run 30756015689 — 5 findings merged,
# 0 reached the posted review. A failed orchestrator is when deterministic
# findings matter MOST.
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"
check "Test 14a: render is not gated on an existing Issues Summary heading" "0" \
  "$(awk '/render-findings-summary.sh/,/^       && \[ -s ci_temp\/issues_summary.md \]/' "$AGG_SH" | grep -c "grep -q '\^## 🔍 Issues Summary'")"
check "Test 14b: replace branch present" "1" \
  "$(grep -c "_fs_mode=\"replaced\"" "$AGG_SH")"
check "Test 14c: insert-before-Recommendation branch present" "1" \
  "$(grep -c 'inserted before Recommendation' "$AGG_SH")"
check "Test 14d: append fallback branch present" "1" \
  "$(grep -c 'appended (orchestrator summary had neither' "$AGG_SH")"
check "Test 14e: splice output is checked before it replaces the summary" "1" \
  "$(grep -c 'if \[ -s ci_temp/pr_summary_main.rendered.md \]; then' "$AGG_SH")"

# --- Test 15: diagnostic logs survive cleanup and reach the console ----------
# The gate rm -rf's ci_temp on always() and uploads no artifact, so naming a
# stderr path in the log pointed at a file that no longer existed by the time
# anyone read it. PR #106 run 30756015689 lost the only evidence of why two
# chunks failed. ci_temp_logs is a SIBLING of ci_temp so the cleanup cannot
# reach it, and the tail goes to the console because workflow logs outlive the
# workspace.
REPORT_SH="$SCRIPT_DIR/lib/report-error-log.sh"
_el="$TMP_DIR/errlog"; mkdir -p "$_el"
printf 'line %s\n' $(seq 1 60) > "$_el/big.log"
out="$(cd "$_el" && bash "$REPORT_SH" "chunk_9_scripts" big.log 3 2>&1)"
check "Test 15a: preserved outside ci_temp (survives rm -rf ci_temp)" "true" \
  "$([ -f "$_el/ci_temp_logs/chunk_9_scripts.log" ] && echo true || echo false)"
check "Test 15b: tail printed to console" "3" \
  "$(printf '%s\n' "$out" | grep -cE '^    line (58|59|60)$')"
check "Test 15c: head of a long log is not dumped" "0" \
  "$(printf '%s\n' "$out" | grep -cE '^    line 1$')"
out_gha="$(cd "$_el" && GITHUB_ACTIONS=1 bash "$REPORT_SH" "chunk_9" big.log 2 2>&1)"
check "Test 15d: collapsible group in Actions" "1" \
  "$(printf '%s\n' "$out_gha" | grep -c '^::group::')"
check "Test 15e: group is closed" "1" \
  "$(printf '%s\n' "$out_gha" | grep -c '^::endgroup::$')"
check "Test 15f: label sanitised into a safe filename" "true" \
  "$(cd "$_el" && bash "$REPORT_SH" "a/b c" big.log 1 >/dev/null 2>&1; [ -f "$_el/ci_temp_logs/a_b_c.log" ] && echo true || echo false)"
for _case in "missing:/nonexistent.log" "empty:$_el/empty.log"; do
  : > "$_el/empty.log"
  ( cd "$_el" && bash "$REPORT_SH" "${_case%%:*}" "${_case##*:}" >/dev/null 2>&1 )
  check "Test 15g: ${_case%%:*} log never fails the caller" "0" "$?"
done
check "Test 15h: wired into the chunk-failure path" "1" \
  "$(grep -c 'lib/report-error-log.sh' "$SCRIPT_DIR/aggregate-reviews.sh")"
check "Test 15i: wired into both chunk failure branches" "2" \
  "$(grep -c 'lib/report-error-log.sh' "$SCRIPT_DIR/review-in-chunks.sh")"

# --- Test 16: escalation's blocking-finding count survives a malformed file --
# aggregate-reviews.sh:857-864 re-counts Critical/High findings from
# $MERGED_FINDINGS_FILE to force REQUEST_CHANGES when the rendered Issues
# Summary disagrees with the orchestrator's decision (LADR-036). The jq filter
# used to be `.findings[] | ...` with no `// []` guard: a `findings` key that
# was missing or wrong-typed made jq error, and `2>/dev/null || echo 0` masked
# that as an ordinary "0 blocking findings" — indistinguishable from a
# genuinely clean file. Extract the real filter from the script (not a copy
# that can drift) and exercise it directly against fixture files.
_agg_jq_filter="$(sed -n "s/^[[:space:]]*BLOCKING_FINDING_COUNT=\$(jq '\(.*\)' \\\\\$/\1/p" "$SCRIPT_DIR/aggregate-reviews.sh")"
check "Test 16a: escalation jq filter extracted from the script" "true" \
  "$([ -n "$_agg_jq_filter" ] && echo true || echo false)"
check "Test 16b: filter guards against a missing findings key" "1" \
  "$(grep -c '(\.findings // \[\])' <<<"$_agg_jq_filter")"

printf '%s' '{"schema_version":1,"findings":[{"severity":"high"},{"severity":"low"}]}' > "$TMP_DIR/agg-valid.json"
check "Test 16c: counts only critical/high in a well-formed file" "1" \
  "$(jq "$_agg_jq_filter" "$TMP_DIR/agg-valid.json" 2>/dev/null)"

printf '%s' '{"schema_version":1}' > "$TMP_DIR/agg-missing-key.json"
_agg_missing_err="$(jq "$_agg_jq_filter" "$TMP_DIR/agg-missing-key.json" 2>&1 >/dev/null)"
check "Test 16d: a missing findings key does not error jq" "true" \
  "$([ -z "$_agg_missing_err" ] && echo true || echo false)"
check "Test 16e: a missing findings key counts as zero blocking findings" "0" \
  "$(jq "$_agg_jq_filter" "$TMP_DIR/agg-missing-key.json" 2>/dev/null)"

printf '%s' '{"schema_version":1,"findings":"not-an-array"}' > "$TMP_DIR/agg-malformed.json"
_agg_out="$(jq "$_agg_jq_filter" "$TMP_DIR/agg-malformed.json" 2>/dev/null || echo "INVALID")"
check "Test 16f: a wrong-typed findings field is surfaced as INVALID, not silently 0" "INVALID" \
  "$_agg_out"

# --- Test 17: `evidence` is optional (sidecar slimming) ---------------------
# The chunk prompt no longer asks for an `evidence` array: it duplicated quotes
# already in the markdown and inflated the block that is emitted last and
# truncated first (PR #106 run 30756015689 at 5/6, PR #111 run 30786473904 at
# 4/5 — the richest chunk truncating its own sidecar both times). `first_evidence`
# alone carries the quote-the-line gate. Older producers that still send
# `evidence` must keep working, and a present-but-junk one is still malformed.
_ev_base='"title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w","confidence":100,"verified":true,"first_evidence":"f:1 -- q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver"'

out="$(printf '[ %s ]' "$(doc 0 "{$_ev_base}")" | merge)"
check "Test 17a: a finding with no evidence array is valid" "1" "$(printf '%s' "$out" | jq '.findings | length')"
check "Test 17b: and is not counted malformed" "0" "$(printf '%s' "$out" | jq -r .malformed_findings)"
check "Test 17c: it keeps confidence 100 (first_evidence satisfies the gate)" "100" \
  "$(printf '%s' "$out" | jq -r '.findings[0].confidence')"

# Build the finding object in a variable first. Writing the braces inline as
# "{$_ev_base,\"evidence\":[...]}" inside a nested command substitution loses the
# quoting: bash brace-expanded `{A,B}` into two separate `doc` calls, the merge
# helper got unparseable JSON, exited 2, and `set -e` killed the whole suite at
# this line — silently taking Tests 18-25 with it.
_ev_with_evidence="{$_ev_base,"'"evidence":["f:1 -- q"]}'
out="$(printf '[ %s ]' "$(doc 0 "$_ev_with_evidence")" | merge)"
check "Test 17d: a legacy finding WITH evidence still validates" "1" "$(printf '%s' "$out" | jq '.findings | length')"

_ev_empty_evidence="{$_ev_base,"'"evidence":[]}'
out="$(printf '[ %s ]' "$(doc 0 "$_ev_empty_evidence")" | merge)"
check "Test 17e: an empty evidence array is still malformed" "1" "$(printf '%s' "$out" | jq -r .malformed_findings)"
_ev_string_evidence="{$_ev_base,"'"evidence":"a string"}'
out="$(printf '[ %s ]' "$(doc 0 "$_ev_string_evidence")" | merge)"
check "Test 17f: a wrong-typed evidence field is still malformed" "1" "$(printf '%s' "$out" | jq -r .malformed_findings)"

# A finding with neither evidence nor first_evidence must still be demoted —
# dropping the array must not have opened a hole in the quote-the-line gate.
_ev_noquote='"title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w","confidence":100,"verified":true,"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver"'
out="$(printf '[ %s ]' "$(doc 0 "{$_ev_noquote}")" | merge)"
check "Test 17g: no evidence AND no first_evidence is still demoted to 50" "50" \
  "$(printf '%s' "$out" | jq -r '.suppressed_findings[0].confidence')"
check "Test 17h: that demotion is still counted" "1" "$(printf '%s' "$out" | jq -r .demoted_no_quote)"

# --- Test 18: partial-coverage rendering ------------------------------------
# Partial coverage is now RENDERED rather than suppressed, so the warning that
# keeps it honest is load-bearing. It must name the missing chunks, and it must
# be absent on full coverage.
if [ -x "$RENDER_SH" ]; then
  cat > "$TMP_DIR/partial.json" <<'PJ'
{"status":"complete","merged_chunks":[0,2],"findings":[{"#":1,"title":"Guard missing","severity":"high","file":"a.cs","line":42,"why_it_matters":"Callers bypass the check.","confidence":100,"verified":true,"first_evidence":"a.cs:42 -- q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"downstream-resolver","chunks":[0]}],"pre_existing_findings":[],"suppressed_findings":[],"residual_risks":[],"testing_gaps":[],"suppressed_by_confidence":{},"demoted_no_quote":0,"merged_duplicates":0,"malformed_findings":0,"malformed_returns":0}
PJ
  bash "$RENDER_SH" "$TMP_DIR/partial.json" 0 3 "1" > "$TMP_DIR/partial.md" 2>/dev/null
  check "Test 18a: partial coverage renders a warning" "1" \
    "$(grep -c 'Partial structured coverage' "$TMP_DIR/partial.md" || true)"
  check "Test 18b: the warning names the missing chunk" "1" \
    "$(grep -c 'Chunk(s) 1 reviewed successfully' "$TMP_DIR/partial.md" || true)"
  check "Test 18c: the Coverage block lists the gap as a line item" "1" \
    "$(grep -c 'Reviewed chunks with no usable sidecar:\*\* chunk(s) 1' "$TMP_DIR/partial.md" || true)"
  check "Test 18d: the surviving finding is still rendered" "1" \
    "$(grep -c 'Guard missing' "$TMP_DIR/partial.md" || true)"

  bash "$RENDER_SH" "$TMP_DIR/partial.json" 0 3 "" > "$TMP_DIR/full.md" 2>/dev/null
  check "Test 18e: full coverage renders NO warning" "0" \
    "$(grep -c 'Partial structured coverage' "$TMP_DIR/full.md" || true)"
  check "Test 18f: full coverage says so explicitly" "1" \
    "$(grep -c 'full structured coverage' "$TMP_DIR/full.md" || true)"
else
  echo "⏭️  render-findings-summary.sh not executable — skipping partial-coverage tests"
fi

# --- Test 19: no identifier can autolink to a GitHub issue (LADR-067) --------
# The bug this pins: GFM autolinks `#` followed by digits to an issue/PR in the
# repo the review is posted on, and `**` does not suppress it. `**#1**` rendered
# as a link carrying issue #1's TITLE — observed in production as a finding
# bullet that began "chore: Initialize projects and folders…" — and each posted
# review left a cross-reference on that repo's low-numbered issues.
#
# The assertion is deliberately blunt: NO `#<digit>` sequence anywhere in a
# rendered summary, whatever produced it. A narrower regex per identifier class
# would pass while some new emitter reintroduced the collision elsewhere.
if [ -x "$RENDER_SH" ]; then
  bash "$RENDER_SH" "$TMP_DIR/merged.json" > "$TMP_DIR/autolink.md"
  check "Test 19a: rendered summary contains no autolinking #<digits>" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/autolink.md" || true)"
  bash "$RENDER_SH" "$TMP_DIR/soft-merged.json" > "$TMP_DIR/autolink-soft.md"
  check "Test 19b: soft-bucket summary contains no autolinking #<digits>" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/autolink-soft.md" || true)"
  bash "$RENDER_SH" "$TMP_DIR/pe-merged.json" > "$TMP_DIR/autolink-pe.md"
  check "Test 19c: pre-existing summary contains no autolinking #<digits>" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/autolink-pe.md" || true)"
  bash "$RENDER_SH" "$TMP_DIR/partial.json" 0 3 "1" > "$TMP_DIR/autolink-partial.md" 2>/dev/null
  check "Test 19d: partial-coverage warning contains no autolinking #<digits>" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/autolink-partial.md" || true)"

  # The chunk heading emitted by aggregate-reviews.sh is the other posted site.
  check "Test 19e: aggregate-reviews.sh emits '### Chunk N', not '### Chunk #N'" "0" \
    "$(grep -c 'echo "### Chunk #' "$AGG_SH" || true)"

  # `1)` is also a CommonMark ordered-list marker, so an unbolded identifier at
  # the head of a bullet (`- 1) foo`) parses as a NESTED list and the number
  # disappears from the rendered text. Every emitted identifier must be bolded.
  # LADR-068: findings are ordered-list items, so the bolding rule no longer
  # applies to them. It still binds the prefixed classes, which remain bullets:
  # `- T1) foo` unbolded is fine (it starts with a letter, not a list marker),
  # but keeping every class bolded means that distinction never has to hold.
  check "Test 19f: prefixed-class bullets bold their identifier" "0" \
    "$(grep -cE '^- [A-Z][0-9]+\) ' "$TMP_DIR/autolink-soft.md" || true)"
fi

# --- Test 20: aggregate-reviews.sh's own identifier surfaces (LADR-067) ------
# Test 19 covers render-findings-summary.sh, which is only the PRIMARY path.
# Two identifier surfaces live in aggregate-reviews.sh instead, and both escaped
# the LADR-067 rename because a grep for the rendered shape cannot see them:
#
#   1. The aggregation prompt's numbering instruction. On the fallback path
#      (structured findings disabled, or the merge returning no document) the
#      orchestrator's free-text Issues Summary is posted VERBATIM, so telling
#      the model to reuse a `#` number reintroduces the autolink there. The
#      instruction is prose inside a heredoc — invisible to any check that
#      looks for the rendered `**#1**`.
#   2. The holistic legend, whose guard greps for the shape
#      `number-holistic-items.sh` emits. Renaming the emitter without the guard
#      left dead code: the guard never matched, so the legend — the only
#      explanation a reader gets for `H1)` on the fallback path — silently
#      stopped rendering, and its text still taught the old shape.
NUMBER_SH="$SCRIPT_DIR/lib/number-holistic-items.sh"

check "Test 20a: aggregation prompt no longer teaches a \`#\` number" "0" \
  "$(grep -cF 'Reuse one stable `#`' "$AGG_SH" || true)"
check "Test 20b: aggregation prompt teaches the trailing-paren identifier" "1" \
  "$(grep -cF 'Reuse one stable `1)` identifier' "$AGG_SH" || true)"

# The legend guard is asserted BEHAVIOURALLY, not by restating its regex here:
# the regex is extracted from the script and run against output from the real
# numberer. Restating it would let guard and emitter drift apart again while
# the test stayed green — which is exactly how this defect shipped. Same
# single-source-of-truth technique as test-minimize-reviews.sh Test 5.
# Accept `grep -q` and `grep -qE` alike. Matching only the current `-qE` form
# made this extraction return empty against the pre-fix script, which skipped
# the behavioural check below entirely — a test that quietly does not run is
# worse than one that fails, so the pattern deliberately spans both forms.
legend_re="$(grep -F 'ci_temp/pr_summary_detailed.md 2>/dev/null' "$AGG_SH" \
  | sed -n "s/.*grep -q[E]* '\([^']*\)'.*/\1/p" | head -1)"
check "Test 20c: the legend guard regex was extractable from the script" "1" \
  "$([ -n "$legend_re" ] && echo 1 || echo 0)"
if [ -n "$legend_re" ] && [ -f "$NUMBER_SH" ]; then
  printf '**Cross-Chunk Issues Found:**\n\n- A real cross-chunk item.\n' \
    > "$TMP_DIR/holistic.md"
  bash "$NUMBER_SH" "$TMP_DIR/holistic.md"
  check "Test 20d: the legend guard matches what number-holistic-items.sh emits" "1" \
    "$(grep -cE "$legend_re" "$TMP_DIR/holistic.md" || true)"
fi

check "Test 20e: the legend text contains no autolinking #<digits>" "0" \
  "$(grep -F 'Cross-chunk items below are numbered' "$AGG_SH" | grep -coE '#[0-9]' || true)"

# 20e alone cannot catch the defect this test exists for: the pre-fix legend
# said `#H1` / `#N`, which is `#` followed by a LETTER and never autolinked.
# Its actual defect was teaching a shape the emitter no longer produces, so a
# reader quoting the legend into a skip bullet wrote an identifier matching
# nothing. Assert the shape positively, not just the absence of the hazard.
# Match on `H1)` without the surrounding backticks: they are backslash-escaped
# inside the echo (\`H1)\`), so a pattern including them matches nothing.
check "Test 20g: the legend text names the current H1) shape" "1" \
  "$(grep -F 'Cross-chunk items below are numbered' "$AGG_SH" | grep -cF 'H1)' || true)"

# --- Test 22: the holistic legend names the shape of the path it ships beside -
# The gate posts ONE body containing both the Issues Summary and the holistic
# legend, and the two are rendered by different code on different paths:
#
#   primary  (FINDINGS_SUMMARY_APPLIED=true)  render-findings-summary.sh -> `1.`
#   fallback (FINDINGS_SUMMARY_APPLIED=false) orchestrator free text      -> `1)`
#
# The fallback keeps `1)` deliberately: that summary is model prose, so its
# per-section numbering is NOT guaranteed contiguous, and an ordered list there
# would silently renumber. Bold literal text cannot.
#
# LADR-068 changed the primary path and left the legend asserting `1)`, so a
# single posted review contradicted itself on the identifier shape — caught in
# production on PR 115, not by this suite. Tests 20b/20g did not cover it: 20g
# greps the legend for `H1)`, which never stopped matching. Nothing asserted the
# findings-shape reference in either branch, which is why the drift was silent.
#
# Executed, not pattern-matched: the block is lifted from the script and run
# under both values, so a future edit to the branch logic is caught rather than
# a future edit to its wording.
_shape_first="$(grep -n '_findings_shape=' "$AGG_SH" | head -1 | cut -d: -f1)"
_shape_last="$(grep -n 'Cross-chunk items below are numbered' "$AGG_SH" | head -1 | cut -d: -f1)"
check "Test 22a: the conditional legend block is present and extractable" "1" \
  "$([ -n "$_shape_first" ] && [ -n "$_shape_last" ] && [ "$_shape_last" -gt "$_shape_first" ] && echo 1 || echo 0)"

if [ -n "$_shape_first" ] && [ -n "$_shape_last" ] && [ "$_shape_last" -gt "$_shape_first" ]; then
  # Start one line above the first assignment to capture the `if` itself, and
  # strip the redirect so the echo lands on stdout.
  sed -n "$((_shape_first - 1)),${_shape_last}p" "$AGG_SH" \
    | sed 's| >> ci_temp/final_review.md||' > "$TMP_DIR/legend_block.sh"

  legend_true="$(FINDINGS_SUMMARY_APPLIED=true  bash "$TMP_DIR/legend_block.sh" 2>/dev/null)"
  legend_false="$(FINDINGS_SUMMARY_APPLIED=false bash "$TMP_DIR/legend_block.sh" 2>/dev/null)"

  check "Test 22b: on the primary path the legend names the 1. findings shape" "1" \
    "$(printf '%s' "$legend_true" | grep -cF '`1.` findings' || true)"
  check "Test 22c: on the primary path it does NOT name the 1) shape" "0" \
    "$(printf '%s' "$legend_true" | grep -cF '`1)` findings' || true)"
  check "Test 22d: on the fallback path the legend names the 1) findings shape" "1" \
    "$(printf '%s' "$legend_false" | grep -cF '`1)` findings' || true)"
  check "Test 22e: on the fallback path it does NOT name the 1. shape" "0" \
    "$(printf '%s' "$legend_false" | grep -cF '`1.` findings' || true)"

  # Both branches keep the holistic sequence and stay autolink-free. The
  # backticks travel through a variable expansion here; bash does not re-scan an
  # expansion for command substitution, but an editor who rewrites this with an
  # unquoted heredoc would silently delete the text (see the repo-wide rule).
  check "Test 22f: both branches still name the H1) holistic sequence" "2" \
    "$(printf '%s\n%s\n' "$legend_true" "$legend_false" | grep -cF 'H1)' || true)"
  check "Test 22g: neither branch emits an autolinking #<digits>" "0" \
    "$(printf '%s\n%s\n' "$legend_true" "$legend_false" | grep -coE '#[0-9]' || true)"

  # An unset variable must fall to the literal form, never to the ordered-list
  # form: the fallback path is where a wrong shape is unrecoverable.
  legend_unset="$(env -u FINDINGS_SUMMARY_APPLIED bash "$TMP_DIR/legend_block.sh" 2>/dev/null)"
  check "Test 22h: an unset flag defaults to the safe literal 1) shape" "1" \
    "$(printf '%s' "$legend_unset" | grep -cF '`1)` findings' || true)"
fi

# --- Test 21: findings render as an ordered list, contiguously (LADR-068) ----
# Two assertions that did not exist before and whose absence was the real gap:
# every check on the findings shape was NEGATIVE ("no `- **N)**` here"), so
# after the LADR-068 rename they all passed vacuously and a regression to the
# old shape would have gone unnoticed.
#
# 21c is the load-bearing one. `N.` is only safe because CommonMark takes the
# start number of an ordered list from its FIRST item and disregards the rest:
# a section holding a non-contiguous subset renders wrong numbers with no error
# anywhere. Contiguity per section is guaranteed by merge-findings.py sorting on
# severity FIRST and numbering only after suppression/partitioning — an
# invariant in a DIFFERENT FILE from the renderer. Reordering that sort_key to
# group by file reads like a harmless improvement and silently rebinds every
# identifier in the posted review. This test is the only thing that catches it.
if [ -x "$RENDER_SH" ] && [ -f "$TMP_DIR/multi.json" ]; then :; fi
cat > "$TMP_DIR/ordered.json" <<'OJ'
{"status":"complete","merged_chunks":[0],"findings":[
{"#":1,"title":"Crit one","severity":"critical","file":"a.sh","line":1,"why_it_matters":"Impact.","confidence":100,"verified":true,"first_evidence":"q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"x","chunks":[0]},
{"#":2,"title":"High one","severity":"high","file":"b.sh","line":2,"why_it_matters":"","confidence":100,"verified":true,"first_evidence":"q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"x","chunks":[0]},
{"#":3,"title":"High two","severity":"high","file":"c.sh","line":3,"why_it_matters":"","confidence":100,"verified":true,"first_evidence":"q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"x","chunks":[0]},
{"#":4,"title":"Med one","severity":"medium","file":"d.sh","line":4,"why_it_matters":"","confidence":100,"verified":true,"first_evidence":"q","pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"x","chunks":[0]}],
"pre_existing_findings":[],"suppressed_findings":[],"residual_risks":[],"testing_gaps":[],"suppressed_by_confidence":{},"demoted_no_quote":0,"merged_duplicates":0,"malformed_findings":0,"malformed_returns":0}
OJ
bash "$RENDER_SH" "$TMP_DIR/ordered.json" 0 1 "" > "$TMP_DIR/ordered.md"

check "Test 21a: findings render as ordered-list items, not bullets" "4" \
  "$(grep -cE '^[0-9]+\. ' "$TMP_DIR/ordered.md" || true)"
check "Test 21b: no finding renders as the pre-LADR-068 bullet" "0" \
  "$(grep -cE '^- \*\*[0-9]+\)\*\* ' "$TMP_DIR/ordered.md" || true)"

# Per severity section, the numbers must form an unbroken ascending run.
#
# This drives the REAL merge over deliberately scrambled input rather than a
# pre-numbered fixture. A hand-numbered fixture is contiguous by construction,
# so it would assert nothing about merge-findings.py — and the invariant being
# pinned IS the sort key in that file. Input order below is low/critical/medium/
# high across two chunks, so only a severity-leading sort can produce a
# contiguous rendering.
# The FILE NAMES are chosen so that sorting by file and sorting by severity
# produce DIFFERENT orders. An earlier version of this fixture named the
# critical finding a.sh and the low one z.sh, which made the two sorts
# coincide — the test passed even with the sort key deliberately broken. Here
# a-file/n-file are high, m-file is medium, z-file is critical, b-file is low,
# so a file-first sort both reorders the sections (caught by 21c3) and puts a
# gap inside the High section (caught by 21c2).
scrambled="[ $(doc 0 "$(finding 'Alpha high' high 'a-file.sh' 1 100 false 'a-file.sh:1 -- q')"),
             $(doc 0 "$(finding 'Bravo low' low 'b-file.sh' 2 100 false 'b-file.sh:2 -- q')"),
             $(doc 1 "$(finding 'Mike med' medium 'm-file.sh' 5 100 false 'm-file.sh:5 -- q')"),
             $(doc 1 "$(finding 'November high' high 'n-file.sh' 6 100 false 'n-file.sh:6 -- q')"),
             $(doc 1 "$(finding 'Zulu crit' critical 'z-file.sh' 9 100 false 'z-file.sh:9 -- q')") ]"
printf '%s' "$scrambled" | merge > "$TMP_DIR/scrambled.json"
bash "$RENDER_SH" "$TMP_DIR/scrambled.json" 0 2 "" > "$TMP_DIR/scrambled.md"

check "Test 21c1: the merge numbered every finding" "5" \
  "$(grep -cE '^[0-9]+\. ' "$TMP_DIR/scrambled.md" || true)"

# Within each `### ` section, numbers must ascend by exactly 1 with no gap.
contig="$(awk '
  /^### /      { prev = 0; next }
  /^[0-9]+\. / { n = $0 + 0; if (prev != 0 && n != prev + 1) bad++; prev = n }
  END          { print bad + 0 }' "$TMP_DIR/scrambled.md")"
check "Test 21c2: each severity section holds a contiguous run of numbers" "0" "$contig"

# And the run must be globally ascending in severity order, which is what makes
# the per-section runs contiguous in the first place.
check "Test 21c3: numbering follows severity order across sections" "1,2,3,4,5" \
  "$(grep -oE '^[0-9]+\.' "$TMP_DIR/scrambled.md" | tr -d '.' | tr '\n' ',' | sed 's/,$//')"

# The continuation line must indent to the content column of `N. ` (3 spaces),
# not the 2 a `- ` bullet used, or it detaches from its item.
check "Test 21d: why_it_matters indents to the ordered-item content column" "1" \
  "$(grep -cE '^   - Impact\.' "$TMP_DIR/ordered.md" || true)"

# The ai-analyse filter groups findings by "what starts a new item". It matched
# only `- ` before LADR-068; against ordered items that silently collapsed the
# whole section into one item and disabled the LADR-056 failing-test guard.
FILTER_SH="$SCRIPT_DIR/../../ai-analyse/scripts/lib/filter-failing-test-findings.sh"
if [ -f "$FILTER_SH" ]; then
  filtered="$(printf '%s\n' \
    '1. 🟡 [VERIFIED] Medium Priority: FooTests.Bar is failing — `a.cs:42` (chunk 0)' \
    '   - The assertion no longer matches.' \
    '2. 🟡 [VERIFIED] Medium Priority: resolve_provider drops the scope flag — `b.sh:1` (chunk 0)' \
    | bash "$FILTER_SH" 2>/dev/null)"
  check "Test 21e: the analyse filter still detects ordered findings as items" "1" \
    "$(printf '%s' "$filtered" | grep -cE '^2\. ' || true)"
  check "Test 21f: the failing-test finding is withheld with its continuation" "0" \
    "$(printf '%s' "$filtered" | grep -cE 'FooTests|assertion no longer' || true)"
fi

# Blunt net over the whole posted body, mirroring test 19's intent one level up:
# every literal line appended to final_review.md is text a reader sees on
# GitHub, so none of them may carry `#<digits>`. Broader than the two surfaces
# above on purpose — a future append is covered without anyone remembering to
# extend this file.
check "Test 20f: no line appended to the posted body carries #<digits>" "0" \
  "$(grep -F '>> ci_temp/final_review.md' "$AGG_SH" | grep -cE '#[0-9]' || true)"

# --- Test 23: a dropped finding says WHY it was dropped -----------------------
# The bug this pins: a review posted "🔵 Low Priority: None found" while its own
# Recommendation counted one low issue and Suggested Fixes showed it. The
# markdown transport had carried the finding and the sidecar entry had not,
# because its `confidence` was 70 — off-anchor, so the whole finding failed
# validation. Coverage reported "Malformed and dropped: 1 finding(s)" and
# stopped there, which named the loss without naming a single actionable thing
# about it. Off-anchor confidence is the dominant cause and a one-line fix once
# it is visible, so it must be visible.
reason_input='[
  {"chunk": 1, "findings": [
    {"title":"a","severity":"low","file":"f.tsx","line":98,"why_it_matters":"w","confidence":70,"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"human"},
    {"title":"b","severity":"low","file":"f.tsx","line":99,"why_it_matters":"w","confidence":70,"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"human"},
    {"title":"c","severity":"high","file":"f.tsx","line":1,"why_it_matters":"w","confidence":100,"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"nobody"}
  ], "residual_risks": [], "testing_gaps": []},
  {"chunk": 2}
]'
out="$(printf '%s' "$reason_input" | merge)"
printf '%s' "$out" > "$TMP_DIR/reasons.json"

check "Test 23a: the off-anchor confidence is named, with its value" "2" \
  "$(printf '%s' "$out" | jq -r '.malformed_reasons["confidence: 70 is not an anchor"]')"
check "Test 23b: a bad enum names the field and the value" "1" \
  "$(printf '%s' "$out" | jq -r '.malformed_reasons["owner: '"'"'nobody'"'"' is not in the vocabulary"]')"
check "Test 23c: reasons aggregate — 3 rejects, 2 causes" "2" \
  "$(printf '%s' "$out" | jq -r '.malformed_reasons | length')"
check "Test 23d: the counts themselves are unchanged" "3 1" \
  "$(printf '%s' "$out" | jq -r '"\(.malformed_findings) \(.malformed_returns)"')"
check "Test 23e: a rejected chunk document reports its own reason" "1" \
  "$(printf '%s' "$out" | jq -r '.malformed_return_reasons["findings: missing"]')"

# Determinism is the same hard requirement the merge itself carries: the eval
# harness diffs byte-for-byte, and a Counter iterated in insertion order would
# reorder run to run.
check "Test 23f: the same input produces byte-identical reasons" "same" \
  "$( [ "$(printf '%s' "$reason_input" | merge)" = "$out" ] && echo same || echo differs )"

if [ -x "$RENDER_SH" ]; then
  bash "$RENDER_SH" "$TMP_DIR/reasons.json" 0 2 "" > "$TMP_DIR/reasons.md"

  check "Test 23g: the reason renders as a sub-bullet under the count" "1" \
    "$(grep -cE '^  - `confidence: 70 is not an anchor` — 2 findings$' "$TMP_DIR/reasons.md" || true)"
  check "Test 23h: a single-item cause is singular, not '1 findings'" "1" \
    "$(grep -cE '^  - .* — 1 finding$' "$TMP_DIR/reasons.md" || true)"
  check "Test 23i: the document reason names its own unit" "1" \
    "$(grep -cF '— 1 chunk document' "$TMP_DIR/reasons.md" || true)"
  # The count bullet is the line three consumers have always seen. Sub-bullets
  # are additive; the parent must not have moved or changed shape.
  check "Test 23j: the pre-existing count bullet is untouched" "1" \
    "$(grep -cF -- '- **Malformed and dropped:** 3 finding(s), 1 chunk document(s)' "$TMP_DIR/reasons.md" || true)"

  # A merged document written before this feature existed — a stale run artifact
  # (LADR-062), an eval fixture — has no reasons key at all and must still render
  # rather than emitting `null` into a posted review.
  jq 'del(.malformed_reasons, .malformed_return_reasons)' "$TMP_DIR/reasons.json" \
    > "$TMP_DIR/reasons-legacy.json"
  bash "$RENDER_SH" "$TMP_DIR/reasons-legacy.json" 0 2 "" > "$TMP_DIR/reasons-legacy.md"
  check "Test 23k: a document with no reasons key still renders the count" "1" \
    "$(grep -cF -- '- **Malformed and dropped:** 3 finding(s), 1 chunk document(s)' "$TMP_DIR/reasons-legacy.md" || true)"
  check "Test 23l: and emits no sub-bullets and no null" "0" \
    "$(grep -cE '^  - `|null' "$TMP_DIR/reasons-legacy.md" || true)"

  # Bounded output: the enum reasons carry the offending value, so fifty distinct
  # off-anchor confidences would otherwise mean fifty sub-bullets in a body
  # GitHub truncates at 65,536 characters.
  many="$("$PY_BIN" - <<'PYEOF'
import json
def f(c):
    return {"title": "t%d" % c, "severity": "high", "file": "f", "line": c,
            "why_it_matters": "w", "confidence": c, "pre_existing": False,
            "requires_verification": False, "autofix_class": "manual", "owner": "human"}
print(json.dumps([{"chunk": 1, "findings": [f(c) for c in range(60, 69)],
                   "residual_risks": [], "testing_gaps": []}]))
PYEOF
)"
  printf '%s' "$many" | merge > "$TMP_DIR/many.json"
  bash "$RENDER_SH" "$TMP_DIR/many.json" 0 1 "" > "$TMP_DIR/many.md"
  check "Test 23m: the cause list is capped at six sub-bullets" "6" \
    "$(grep -cE '^  - `' "$TMP_DIR/many.md" || true)"
  check "Test 23n: the overflow is stated, not silently dropped" "1" \
    "$(grep -cF '…and 3 further causes' "$TMP_DIR/many.md" || true)"

  # LADR-067, at the one surface where model-authored text reaches a posted body
  # through a NEW path. `severity` here holds an issue reference, a newline and
  # more than VALUE_CAP characters; all three must be neutralised.
  hostile='[{"chunk": 1, "findings": [
    {"title":"a","severity":"BLOCKER #42 plus a tail long enough to need capping","file":"f","line":1,"why_it_matters":"w","confidence":100,"pre_existing":false,"requires_verification":false,"autofix_class":"gated_auto","owner":"human"}
  ], "residual_risks": [], "testing_gaps": []}]'
  printf '%s' "$hostile" | merge > "$TMP_DIR/hostile.json"
  bash "$RENDER_SH" "$TMP_DIR/hostile.json" 0 1 "" > "$TMP_DIR/hostile.md"
  check "Test 23o: a rejected value cannot smuggle #<digits> into the body" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/hostile.md" || true)"
  check "Test 23p: a rejected value cannot smuggle a newline into the bullet" "1" \
    "$(grep -cE '^  - `severity: .* is not one of the four` — 1 finding$' "$TMP_DIR/hostile.md" || true)"
  # Scoped to the sub-bullet: the section Note carries an unrelated ellipsis.
  check "Test 23q: an over-long value is capped with an ellipsis" "1" \
    "$(grep -cE '^  - `severity: .*…' "$TMP_DIR/hostile.md" || true)"

  # The Coverage block sits after the Low section, so a sub-bullet must not leak
  # into what the autonomous fixer treats as a finding.
  if [ -x "$ANALYSE_SCOPE_SH" ]; then
    check "Test 23r: reason sub-bullets stay out of the ai-analyse scope" "0" \
      "$(bash "$ANALYSE_SCOPE_SH" < "$TMP_DIR/reasons.md" 2>/dev/null | grep -cF 'is not an anchor' || true)"
  fi
fi

# --- Test 24: missing requires_verification is defaulted, not dropped (issue #125) ---
# Production failure: gpt-5.6-sol emitted confidence-100 [VERIFIED] findings with
# no requires_verification field; merge counted them malformed and the posted
# Issues Summary said "None found" under a REQUEST_CHANGES verdict. Absent must
# default to false; present-but-wrong-type must still reject.
missing_rv='[{"chunk":0,"findings":[{
  "title":"Canonical identifier inherits mutable state",
  "severity":"high",
  "file":"CardIdentifier.cs",
  "line":23,
  "why_it_matters":"Callers observe shared mutable identity.",
  "confidence":100,
  "verified":true,
  "first_evidence":"CardIdentifier.cs:23 -- public sealed class CardIdentifier",
  "pre_existing":false,
  "autofix_class":"gated_auto",
  "owner":"downstream-resolver"
},{
  "title":"Diagnostics path skips null guard",
  "severity":"medium",
  "file":"CardIdentifierDiagnostics.cs",
  "line":20,
  "why_it_matters":"Null input throws instead of a structured error.",
  "confidence":100,
  "verified":true,
  "first_evidence":"CardIdentifierDiagnostics.cs:20 -- return value.ToString();",
  "pre_existing":false,
  "autofix_class":"manual",
  "owner":"human"
}],"residual_risks":[],"testing_gaps":[]}]'
out="$(printf '%s' "$missing_rv" | merge)"
check "Test 24a: missing requires_verification does not count as malformed" "0" \
  "$(printf '%s' "$out" | jq -r .malformed_findings)"
check "Test 24b: both findings survive into the actionable set" "2" \
  "$(printf '%s' "$out" | jq '.findings | length')"
check "Test 24c: high finding is present (gates the verdict)" "1" \
  "$(printf '%s' "$out" | jq '[.findings[] | select(.severity=="high")] | length')"
check "Test 24d: requires_verification defaults to false" "false" \
  "$(printf '%s' "$out" | jq -r '.findings[0].requires_verification')"
check "Test 24e: medium finding also defaulted" "false" \
  "$(printf '%s' "$out" | jq -r '.findings[] | select(.severity=="medium") | .requires_verification')"

# Wrong-typed present value must still reject — defaulting is for ABSENCE only.
bad_rv_type='[{"chunk":0,"findings":[{
  "title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w",
  "confidence":100,"verified":true,"first_evidence":"f:1 -- q",
  "pre_existing":false,"requires_verification":"yes",
  "autofix_class":"gated_auto","owner":"downstream-resolver"
}],"residual_risks":[],"testing_gaps":[]}]'
out="$(printf '%s' "$bad_rv_type" | merge)"
check "Test 24f: wrong-typed requires_verification is still malformed" "1" \
  "$(printf '%s' "$out" | jq -r .malformed_findings)"
check "Test 24g: wrong-typed requires_verification reason is typed" "requires_verification: wrong type, got string" \
  "$(printf '%s' "$out" | jq -r '.malformed_reasons | keys[0]')"
check "Test 24h: wrong-typed finding does not survive" "0" \
  "$(printf '%s' "$out" | jq '.findings | length')"

# Explicit true must still OR across a dedup group (regression against Test 5c).
rv_true='[{"chunk":0,"findings":[{
  "title":"t","severity":"high","file":"f","line":1,"why_it_matters":"w",
  "confidence":100,"verified":true,"first_evidence":"f:1 -- q",
  "pre_existing":false,"requires_verification":true,
  "autofix_class":"gated_auto","owner":"downstream-resolver"
}],"residual_risks":[],"testing_gaps":[]}]'
out="$(printf '%s' "$rv_true" | merge)"
check "Test 24i: explicit requires_verification true is preserved" "true" \
  "$(printf '%s' "$out" | jq -r '.findings[0].requires_verification')"

# --- Test 25: Recommendation sync from merged findings (issue #125) ----------
SYNC_SH="$SCRIPT_DIR/lib/sync-recommendation-from-findings.sh"
if [ -x "$SYNC_SH" ]; then
  # Build a merged document with 1 high + 1 medium (the production shape).
  printf '%s' "$missing_rv" | merge > "$TMP_DIR/sync-merged.json"

  cat > "$TMP_DIR/sync-summary.md" <<'EOF'
## 🔍 Issues Summary
### 🔴 Critical Issues
None found
## 🎯 Recommendation
**Step 1: Count ACTUAL issues in your "Issues Summary" section above**
- Count of 🔴 Critical Issues: 0
- Count of 🟠 High Priority Issues: 1
- Count of 🟡 Medium Priority Issues: 1
- Count of 🔵 Low Priority Issues: 0
- Count of 🗂️ Pre-existing issues: 0 — these do NOT block the PR

**Decision:** REQUEST CHANGES
**Rationale:** Following policy: 0 critical and 1 high priority issue found - requesting changes.
**MACHINE_READABLE_ACTION:** REQUEST_CHANGES
EOF

  # Empty holistic — decision comes purely from merged findings.
  : > "$TMP_DIR/sync-holistic.md"
  decision="$(bash "$SYNC_SH" "$TMP_DIR/sync-merged.json" "$TMP_DIR/sync-summary.md" "$TMP_DIR/sync-holistic.md" 2>"$TMP_DIR/sync.err")"
  check "Test 25a: high finding forces request_changes" "request_changes" "$decision"
  check "Test 25b: high count rewritten to 1" "1" \
    "$(grep -E 'Count of 🟠 High Priority Issues:' "$TMP_DIR/sync-summary.md" | grep -oE '[0-9]+' | head -1)"
  check "Test 25c: medium count rewritten to 1" "1" \
    "$(grep -E 'Count of 🟡 Medium Priority Issues:' "$TMP_DIR/sync-summary.md" | grep -oE '[0-9]+' | head -1)"
  check "Test 25d: MACHINE_READABLE_ACTION is REQUEST_CHANGES" "1" \
    "$(grep -cF '**MACHINE_READABLE_ACTION:** REQUEST_CHANGES' "$TMP_DIR/sync-summary.md" || true)"
  check "Test 25e: pre-existing trailing note and bullet prefix preserved" "1" \
    "$(grep -cF -- '- Count of 🗂️ Pre-existing issues: 0 — these do NOT block the PR' "$TMP_DIR/sync-summary.md" || true)"

  # Empty merged findings + orchestrator still saying REQUEST_CHANGES (the
  # production contradiction after a hard drop) must soften to approve when
  # holistic has nothing blocking.
  cat > "$TMP_DIR/sync-empty-merged.json" <<'EOF'
{"status":"complete","merged_chunks":[0],"findings":[],"pre_existing_findings":[],"suppressed_findings":[],"residual_risks":[],"testing_gaps":[],"suppressed_by_confidence":{},"demoted_no_quote":0,"merged_duplicates":0,"malformed_findings":2,"malformed_returns":0,"malformed_reasons":{"requires_verification: missing":2},"malformed_return_reasons":{}}
EOF
  cat > "$TMP_DIR/sync-empty-summary.md" <<'EOF'
## 🎯 Recommendation
- Count of 🔴 Critical Issues: 0
- Count of 🟠 High Priority Issues: 1
- Count of 🟡 Medium Priority Issues: 1
- Count of 🔵 Low Priority Issues: 0
- Count of 🗂️ Pre-existing issues: 0 — these do NOT block the PR
**Decision:** REQUEST CHANGES
**Rationale:** Following policy: 0 critical and 1 high priority issue found - requesting changes.
**MACHINE_READABLE_ACTION:** REQUEST_CHANGES
EOF
  : > "$TMP_DIR/sync-empty-holistic.md"
  decision="$(bash "$SYNC_SH" "$TMP_DIR/sync-empty-merged.json" "$TMP_DIR/sync-empty-summary.md" "$TMP_DIR/sync-empty-holistic.md" 2>/dev/null)"
  check "Test 25f: empty merged + no holistic softens to approve" "approve" "$decision"
  check "Test 25g: high count rewritten to 0" "0" \
    "$(grep -E 'Count of 🟠 High Priority Issues:' "$TMP_DIR/sync-empty-summary.md" | grep -oE '[0-9]+' | head -1)"
  check "Test 25h: MACHINE_READABLE_ACTION is APPROVE" "1" \
    "$(grep -cF '**MACHINE_READABLE_ACTION:** APPROVE' "$TMP_DIR/sync-empty-summary.md" || true)"
  check "Test 25i: rationale no longer claims a high finding" "0" \
    "$(grep -cE '1 high priority' "$TMP_DIR/sync-empty-summary.md" || true)"

  # Holistic Critical/High still blocks even when merged is empty.
  cat > "$TMP_DIR/sync-holistic-block.md" <<'EOF'
## 🔄 Holistic Cross-Chunk Analysis
**Cross-Chunk Issues Found:**

🔴 **Critical Issues**
- **H1)** Auth middleware registration is missing across both API chunks

🟠 **High Priority Issues**
None found
EOF
  cat > "$TMP_DIR/sync-empty-summary2.md" <<'EOF'
## 🎯 Recommendation
- Count of 🔴 Critical Issues: 0
- Count of 🟠 High Priority Issues: 0
- Count of 🟡 Medium Priority Issues: 0
- Count of 🔵 Low Priority Issues: 0
- Count of 🗂️ Pre-existing issues: 0 — these do NOT block the PR
**Decision:** APPROVE
**Rationale:** Following policy: Only 0 medium and 0 low priority issues found - approving.
**MACHINE_READABLE_ACTION:** APPROVE
EOF
  decision="$(bash "$SYNC_SH" "$TMP_DIR/sync-empty-merged.json" "$TMP_DIR/sync-empty-summary2.md" "$TMP_DIR/sync-holistic-block.md" 2>/dev/null)"
  check "Test 25j: holistic Critical still forces request_changes" "request_changes" "$decision"
  check "Test 25k: holistic rationale names the holistic path" "1" \
    "$(grep -cF 'holistic cross-chunk' "$TMP_DIR/sync-empty-summary2.md" || true)"
else
  echo "⏭️  sync-recommendation-from-findings.sh missing — skipping Test 25"
fi

# --- Test 26: the sync may only soften where softening is evidence ----------
# Every assertion here is a regression guard for a way the issue-#125 sync could
# post a GREENER state than the document it renders from.
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"
ANNOTATE_SH="$SCRIPT_DIR/lib/annotate-suggested-fixes.sh"
if [ -x "$SYNC_SH" ]; then
  cat > "$TMP_DIR/s26-medium.json" <<'MJ'
{"status":"complete","merged_chunks":[0],"findings":[{"severity":"medium"}],"pre_existing_findings":[],"suppressed_findings":[],"malformed_findings":0,"demoted_no_quote":0}
MJ

  # A model that writes its holistic blockers as severity-prefixed bullets
  # instead of under the template's subsection headings must still gate. The
  # first implementation matched those bullets AS headings and counted zero.
  printf '**Cross-Chunk Issues Found:**\n\n- **H1)** 🔴 Critical: shared DbContext across parallel tasks.\n- **H2)** 🟠 High: removed method still called.\n' \
    > "$TMP_DIR/s26-h-inline.md"
  printf '## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** REQUEST_CHANGES\n' > "$TMP_DIR/s26-a.md"
  check "Test 26a: severity-prefixed holistic bullets still block" "request_changes" \
    "$(bash "$SYNC_SH" "$TMP_DIR/s26-medium.json" "$TMP_DIR/s26-a.md" "$TMP_DIR/s26-h-inline.md" 2>/dev/null)"

  # The template's own layout must keep working.
  printf '**Cross-Chunk Issues Found:**\n\n🔴 **Critical Issues**\n- **H1)** Auth middleware missing.\n\n🟠 **High Priority Issues**\nNone found\n' \
    > "$TMP_DIR/s26-h-heading.md"
  printf '## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** APPROVE\n' > "$TMP_DIR/s26-b.md"
  check "Test 26b: heading-style holistic Critical still blocks" "request_changes" \
    "$(bash "$SYNC_SH" "$TMP_DIR/s26-medium.json" "$TMP_DIR/s26-b.md" "$TMP_DIR/s26-h-heading.md" 2>/dev/null)"

  # ...and a holistic section with nothing blocking must NOT invent a block:
  # placeholders, a Medium bullet and the trailing prose bullets are all benign.
  printf '**Cross-Chunk Issues Found:**\n\n🔴 **Critical Issues**\n- None found\n\n🟡 **Medium Priority Issues**\n- 🟡 Medium: naming drift.\n\n**Additional Analysis:**\n- **Consistency:** fine\n' \
    > "$TMP_DIR/s26-h-clean.md"
  printf '## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** REQUEST_CHANGES\n' > "$TMP_DIR/s26-c.md"
  check "Test 26c: a holistic section with no blocker does not block" "approve" \
    "$(bash "$SYNC_SH" "$TMP_DIR/s26-medium.json" "$TMP_DIR/s26-c.md" "$TMP_DIR/s26-h-clean.md" 2>/dev/null)"

  # Count rewriting must survive the label shapes a model actually emits: bold
  # labels, an unfilled template placeholder, and trailing prose.
  cat > "$TMP_DIR/s26-counts.md" <<'CM'
## 🎯 Recommendation
- Count of 🔴 Critical Issues: [number - DO NOT count "None found" as an issue]
- **Count of 🟠 High Priority Issues:** 4
- Count of 🟡 Medium Priority Issues: 7 (see below)
- **Count of 🗂️ Pre-existing issues:** 5 — these do NOT block the PR
**MACHINE_READABLE_ACTION:** REQUEST_CHANGES
CM
  bash "$SYNC_SH" "$TMP_DIR/s26-medium.json" "$TMP_DIR/s26-counts.md" >/dev/null 2>&1 || true
  check "Test 26d: an unfilled count placeholder is replaced by the number" "1" \
    "$(grep -cF -- '- Count of 🔴 Critical Issues: 0' "$TMP_DIR/s26-counts.md" || true)"
  check "Test 26e: a bold count label is rewritten, emphasis intact" "1" \
    "$(grep -cF -- '- **Count of 🟠 High Priority Issues:** 0' "$TMP_DIR/s26-counts.md" || true)"
  check "Test 26f: a stale bold count never survives the sync" "0" \
    "$(grep -cF -- 'High Priority Issues:** 4' "$TMP_DIR/s26-counts.md" || true)"
  check "Test 26g: trailing prose after a count is preserved" "1" \
    "$(grep -cF -- '- Count of 🟡 Medium Priority Issues: 1 (see below)' "$TMP_DIR/s26-counts.md" || true)"
  check "Test 26h: bold pre-existing label keeps its note and is not duplicated" "1" \
    "$(grep -cF -- '- **Count of 🗂️ Pre-existing issues:** 0 — these do NOT block the PR' "$TMP_DIR/s26-counts.md" || true)"

  # A deliberate COMMENT verdict must not be upgraded into a real GitHub APPROVE.
  printf '## 🎯 Recommendation\n**Decision:** COMMENT\n**MACHINE_READABLE_ACTION:** COMMENT\n' > "$TMP_DIR/s26-comment.md"
  check "Test 26i: an orchestrator COMMENT is preserved, not upgraded" "comment" \
    "$(SYNC_ORIGINAL_ACTION=COMMENT bash "$SYNC_SH" "$TMP_DIR/s26-medium.json" "$TMP_DIR/s26-comment.md" 2>/dev/null)"
  check "Test 26j: the posted action matches that decision" "1" \
    "$(grep -cF '**MACHINE_READABLE_ACTION:** COMMENT' "$TMP_DIR/s26-comment.md" || true)"
  printf '## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** REQUEST_CHANGES\n' > "$TMP_DIR/s26-soften.md"
  check "Test 26k: a REQUEST_CHANGES with no surviving blocker still softens" "approve" \
    "$(SYNC_ORIGINAL_ACTION=REQUEST_CHANGES bash "$SYNC_SH" "$TMP_DIR/s26-medium.json" "$TMP_DIR/s26-soften.md" 2>/dev/null)"
else
  echo "⏭️  sync-recommendation-from-findings.sh missing — skipping Test 26a-k"
fi

# Coverage preconditions live in the caller, so assert them at the source: a
# refactor that drops one reopens a fail-open path that no unit test of the sync
# script itself can see. Summary failure alone is intentionally not a guard:
# complete chunk output plus full sidecar coverage owns the deterministic verdict.
if [ -f "$AGG_SH" ]; then
  check "Test 26l: the sync is skipped on partial sidecar coverage" "1" \
    "$(awk '/Recommendation NOT synced/ && /partial sidecar coverage/ {n++} END{print n+0}' "$AGG_SH")"
  check "Test 26m: partial coverage is the guard, not just the message" "1" \
    "$(awk '/if \[ -n "\$MISSING_SIDECAR_CHUNKS" \]/{f=1} f && /Recommendation NOT synced/{print 1; exit}' "$AGG_SH")"
  check "Test 26n: summary failure skips sync only while a chunk remains failed" "1" \
    "$(awk '/elif \[ "\$\{agg_ok:-true\}" != "true" \] && \[ "\$\{FAILED_CHUNK_COUNT:-0\}" -gt 0 \]/{print 1; exit}' "$AGG_SH")"
  check "Test 26n2: recovered chunks let full sidecars decide after summary failure" "1" \
    "$(grep -cF 'Summary generation failed, but all chunks completed with full structured coverage — using the deterministic findings decision' "$AGG_SH" || true)"
  check "Test 26o: the orchestrator action is forwarded so COMMENT survives" "1" \
    "$(awk '/SYNC_ORIGINAL_ACTION="\$\{ORCHESTRATOR_ACTION:-\}"/{print 1; exit}' "$AGG_SH")"
  check "Test 26p: the escalate-only fallback still guards the skip paths" "1" \
    "$(awk '/if \[ -z "\$\{FINDINGS_SYNCED_DECISION:-\}" \]/{print 1; exit}' "$AGG_SH")"
fi

# --- Test 27: Suggested Fixes reconciliation note ---------------------------
if [ -x "$ANNOTATE_SH" ]; then
  cat > "$TMP_DIR/s27-dropped.json" <<'DJ'
{"status":"complete","merged_chunks":[0],"findings":[],"pre_existing_findings":[],"suppressed_findings":[{"x":1}],"malformed_findings":2,"demoted_no_quote":1}
DJ
  printf '## 🔍 Issues Summary\nx\n\n## 📝 Suggested Fixes\n1. Normalize reader byte order.\n\n## 🎯 Recommendation\n' \
    > "$TMP_DIR/s27.md"
  bash "$ANNOTATE_SH" "$TMP_DIR/s27-dropped.json" "$TMP_DIR/s27.md" 2>/dev/null || true
  check "Test 27a: a note explains fixes with no numbered finding" "1" \
    "$(grep -c 'Some suggested fixes may have no numbered finding' "$TMP_DIR/s27.md" || true)"
  check "Test 27b: it names the malformed count" "1" \
    "$(grep -c '2 finding(s) were dropped as malformed' "$TMP_DIR/s27.md" || true)"
  check "Test 27c: it names the suppressed count" "1" \
    "$(grep -c '1 were suppressed below the actionable confidence anchor' "$TMP_DIR/s27.md" || true)"
  check "Test 27d: it names the demotion count" "1" \
    "$(grep -c '1 were demoted for not quoting the motivating line' "$TMP_DIR/s27.md" || true)"
  check "Test 27e: the suggested fix itself survives" "1" \
    "$(grep -c 'Normalize reader byte order' "$TMP_DIR/s27.md" || true)"
  check "Test 27f: LADR-067 — the note autolinks nothing" "0" \
    "$(grep -cE '#[0-9]' "$TMP_DIR/s27.md" || true)"
  bash "$ANNOTATE_SH" "$TMP_DIR/s27-dropped.json" "$TMP_DIR/s27.md" 2>/dev/null || true
  check "Test 27g: it is idempotent" "1" \
    "$(grep -c 'Some suggested fixes may have no numbered finding' "$TMP_DIR/s27.md" || true)"

  cat > "$TMP_DIR/s27-clean.json" <<'CJ'
{"status":"complete","merged_chunks":[0],"findings":[],"pre_existing_findings":[],"suppressed_findings":[],"malformed_findings":0,"demoted_no_quote":0}
CJ
  printf '## 📝 Suggested Fixes\n1. x\n' > "$TMP_DIR/s27-clean.md"
  bash "$ANNOTATE_SH" "$TMP_DIR/s27-clean.json" "$TMP_DIR/s27-clean.md" 2>/dev/null || true
  check "Test 27h: nothing dropped means no note at all" "0" \
    "$(grep -c 'Some suggested fixes' "$TMP_DIR/s27-clean.md" || true)"
  printf 'no heading here\n' > "$TMP_DIR/s27-noheading.md"
  bash "$ANNOTATE_SH" "$TMP_DIR/s27-dropped.json" "$TMP_DIR/s27-noheading.md" 2>/dev/null
  check "Test 27i: a summary with no Suggested Fixes heading is untouched" "no heading here" \
    "$(cat "$TMP_DIR/s27-noheading.md")"
  bash "$ANNOTATE_SH" "$TMP_DIR/missing.json" "$TMP_DIR/s27-clean.md" 2>/dev/null
  check "Test 27j: a missing merged document never fails the caller" "0" "$?"
else
  echo "⏭️  annotate-suggested-fixes.sh missing — skipping Test 27"
fi

# --- Test 28: Suggested Fixes cross-references track the merged numbering ----
# The regression: the orchestrator numbers `finding N` against the Issues
# Summary IT wrote, the LADR-055 splice replaces that summary with one
# merge-findings.py numbered by severity-then-confidence, and every reference
# silently repoints. Fixture is the real shape from consumer PR 95 run
# 35640330645, where the merge promoted AGENTS.md from third to first.
RENUM_SH="$SCRIPT_DIR/lib/renumber-suggested-fixes.sh"
if [ -f "$RENUM_SH" ] && command -v jq >/dev/null 2>&1; then
  cat > "$TMP_DIR/s28.json" <<'RJ'
{"status":"complete","merged_chunks":[0],
 "findings":[
   {"#":1,"severity":"medium","file":"AGENTS.md","line":85},
   {"#":2,"severity":"medium","file":".github/workflows/pipeline-ai-analyse.yml","line":83},
   {"#":3,"severity":"medium","file":".github/workflows/pipeline-code-review-report.yml","line":7},
   {"#":4,"severity":"medium","file":"docs/wiki/ci.md","line":52}],
 "pre_existing_findings":[],
 "suppressed_findings":[{"severity":"low","file":"docs/wiki/ci.md","line":161}],
 "malformed_findings":0,"demoted_no_quote":0}
RJ
  cat > "$TMP_DIR/s28.md" <<'RM'
## 🔍 Issues Summary
rendered from the merged set

## 📝 Suggested Fixes

### `.github/workflows/pipeline-ai-analyse.yml:81-83`
**Issue**: Stale comment claims the gate pins by SHA (🟡 Medium, finding 1)
```yaml
          # see finding 1 for the rationale
          ref: main
```

### `.github/workflows/pipeline-code-review-report.yml:7`
**Issue**: Header still promises a SHA-pinned checkout (🟡 Medium, finding 2)

### `AGENTS.md:85`
**Issue**: Bullet still says "at a pinned SHA" (🟡 Medium, finding 3)

### `docs/wiki/ci.md:52-53`
**Issue**: Packaging bullet documents a pinned SHA (🟡 Medium, finding 4)

### `docs/wiki/ci.md:87,161`
**Issue**: Post-v2 asset claims are unverified (🔵 Low, finding 5)

## 🎯 Recommendation
Aggregates findings 1-4 above; see finding 3 in the holistic notes.
RM
  bash "$RENUM_SH" "$TMP_DIR/s28.json" "$TMP_DIR/s28.md" 2>/dev/null || true

  check "Test 28a: a promoted finding is repointed (AGENTS.md 3 -> 1)" "1" \
    "$(grep -cF 'at a pinned SHA" (🟡 Medium, finding 1)' "$TMP_DIR/s28.md" || true)"
  check "Test 28b: the demoted one follows it (analyse 1 -> 2)" "1" \
    "$(grep -cF 'pins by SHA (🟡 Medium, finding 2)' "$TMP_DIR/s28.md" || true)"
  check "Test 28c: and the third (gate 2 -> 3)" "1" \
    "$(grep -cF 'SHA-pinned checkout (🟡 Medium, finding 3)' "$TMP_DIR/s28.md" || true)"
  check "Test 28d: a correct-by-coincidence reference is left correct" "1" \
    "$(grep -cF 'documents a pinned SHA (🟡 Medium, finding 4)' "$TMP_DIR/s28.md" || true)"
  # The load-bearing one. ci.md carries BOTH a numbered finding (line 52) and a
  # suppressed one (line 161); a file-only match would hand the suppressed block
  # finding 4 and point the reader at an unrelated fix.
  check "Test 28e: an anchor the merge suppressed loses its number, not its neighbour" "1" \
    "$(grep -cF 'are unverified (🔵 Low, no numbered finding)' "$TMP_DIR/s28.md" || true)"
  check "Test 28f: no stale number survives anywhere in the section" "0" \
    "$(awk '/^## 📝 Suggested Fixes/{f=1} f&&/^## 🎯/{f=0} f' "$TMP_DIR/s28.md" | grep -cF 'finding 5' || true)"
  check "Test 28g: fenced code inside a fix block is never rewritten" "1" \
    "$(grep -cF '# see finding 1 for the rationale' "$TMP_DIR/s28.md" || true)"
  check "Test 28h: sections outside Suggested Fixes stay verbatim (LADR-005)" "1" \
    "$(grep -cF 'Aggregates findings 1-4 above; see finding 3 in the holistic notes.' "$TMP_DIR/s28.md" || true)"
  check "Test 28i: LADR-067 — the rewrite autolinks nothing" "0" \
    "$(awk '/^## 📝 Suggested Fixes/{f=1} f&&/^## 🎯/{f=0} f' "$TMP_DIR/s28.md" | grep -cE '#[0-9]' || true)"
  cp "$TMP_DIR/s28.md" "$TMP_DIR/s28-again.md"
  bash "$RENUM_SH" "$TMP_DIR/s28.json" "$TMP_DIR/s28-again.md" 2>/dev/null || true
  check "Test 28j: it is idempotent" "" \
    "$(diff "$TMP_DIR/s28.md" "$TMP_DIR/s28-again.md" || true)"

  # Two findings in one file close enough that the tolerance cannot separate
  # them. Guessing here would reintroduce the exact defect, so the reference is
  # left as the model wrote it.
  cat > "$TMP_DIR/s28-ambig.json" <<'AJ'
{"status":"complete","merged_chunks":[0],
 "findings":[{"#":1,"severity":"high","file":"src/a.ts","line":50},
             {"#":2,"severity":"high","file":"src/a.ts","line":55}],
 "pre_existing_findings":[],"suppressed_findings":[],
 "malformed_findings":0,"demoted_no_quote":0}
AJ
  printf '## 📝 Suggested Fixes\n\n### `src/a.ts:52`\n**Issue**: something (🟠 High, finding 7)\n' \
    > "$TMP_DIR/s28-ambig.md"
  bash "$RENUM_SH" "$TMP_DIR/s28-ambig.json" "$TMP_DIR/s28-ambig.md" 2>/dev/null || true
  check "Test 28k: an ambiguous anchor is left untouched rather than guessed" "1" \
    "$(grep -cF '(🟠 High, finding 7)' "$TMP_DIR/s28-ambig.md" || true)"

  # A heading quoting a hunk range that misses the sidecar line by a few lines
  # must still resolve — that drift is the normal case, not an error.
  cat > "$TMP_DIR/s28-tol.json" <<'TJ'
{"status":"complete","merged_chunks":[0],
 "findings":[{"#":1,"severity":"low","file":"src/b.ts","line":85}],
 "pre_existing_findings":[],"suppressed_findings":[],
 "malformed_findings":0,"demoted_no_quote":0}
TJ
  printf '## 📝 Suggested Fixes\n\n### `src/b.ts:90`\n**Issue**: drifted anchor (🔵 Low, finding 4)\n' \
    > "$TMP_DIR/s28-tol.md"
  # Plural references stay untouched: one anchor cannot resolve a set. Detecting
  # only a trailing `-` or `,` was not enough (review 5271360715, finding 2) --
  # prose separators rewrote the FIRST number and left the rest, so
  # "findings 1 and 2" became "findings 7 and 2", which points the reader at one
  # correct and one wrong finding. Worse than leaving it alone.
  cat > "$TMP_DIR/s28-plural.json" <<'PJ'
{"status":"complete","merged_chunks":[0],
 "findings":[{"#":7,"severity":"medium","file":"src/a.ts","line":10},
             {"#":8,"severity":"medium","file":"src/b.ts","line":20}],
 "pre_existing_findings":[],"suppressed_findings":[],
 "malformed_findings":0,"demoted_no_quote":0}
PJ
  printf '## 📝 Suggested Fixes\n\n### `src/a.ts:10`\n**Issue**: aggregates findings 1 and 2\n**Issue**: see findings 1 through 2\n**Issue**: either findings 1 or 2\n**Issue**: covers findings 1-2\n**Issue**: covers findings 1, 2\n**Issue**: singular finding 1 here\n' \
    > "$TMP_DIR/s28-plural.md"
  bash "$RENUM_SH" "$TMP_DIR/s28-plural.json" "$TMP_DIR/s28-plural.md" 2>/dev/null || true
  for _sep in "and" "through" "or"; do
    check "Test 28q: a plural reference joined by \"$_sep\" is left untouched" "1" \
      "$(grep -cF "findings 1 $_sep 2" "$TMP_DIR/s28-plural.md" || true)"
  done
  check "Test 28r: punctuation-joined plurals still untouched" "2" \
    "$(grep -cE 'findings 1[-,] ?2' "$TMP_DIR/s28-plural.md" || true)"
  check "Test 28s: no plural reference was partially rewritten" "0" \
    "$(grep -cE 'findings 7' "$TMP_DIR/s28-plural.md" || true)"
  check "Test 28t: a singular reference under the same anchor still repoints" "1" \
    "$(grep -cF 'singular finding 7 here' "$TMP_DIR/s28-plural.md" || true)"

  # Repeated SINGULAR references slipped past both plural guards: each match
  # looked solitary on its own, so both were rewritten to this anchor number,
  # collapsing two distinct references onto one (review 5271520178, finding 3).
  # One anchor resolves one finding, so a line naming several is left alone.
  printf '## 📝 Suggested Fixes\n\n### `src/a.ts:10`\n**Issue**: see finding 1 and finding 2 both\n**Issue**: solitary finding 1 here\n' \
    > "$TMP_DIR/s28-repeat.md"
  bash "$RENUM_SH" "$TMP_DIR/s28-plural.json" "$TMP_DIR/s28-repeat.md" 2>/dev/null || true
  check "Test 28u: repeated singular references are left untouched" "1" \
    "$(grep -cF 'see finding 1 and finding 2 both' "$TMP_DIR/s28-repeat.md" || true)"
  check "Test 28v: no two references collapse onto one number" "0" \
    "$(grep -cE 'finding 7 and finding 7' "$TMP_DIR/s28-repeat.md" || true)"
  check "Test 28w: a solitary reference on its own line still repoints" "1" \
    "$(grep -cF 'solitary finding 7 here' "$TMP_DIR/s28-repeat.md" || true)"
  bash "$RENUM_SH" "$TMP_DIR/s28-tol.json" "$TMP_DIR/s28-tol.md" 2>/dev/null || true
  check "Test 28l: a heading line-spec within tolerance still resolves" "1" \
    "$(grep -cF 'drifted anchor (🔵 Low, finding 1)' "$TMP_DIR/s28-tol.md" || true)"

  printf 'no heading here\n' > "$TMP_DIR/s28-noheading.md"
  bash "$RENUM_SH" "$TMP_DIR/s28.json" "$TMP_DIR/s28-noheading.md" 2>/dev/null
  check "Test 28m: a summary with no Suggested Fixes heading is untouched" "no heading here" \
    "$(cat "$TMP_DIR/s28-noheading.md")"
  bash "$RENUM_SH" "$TMP_DIR/missing.json" "$TMP_DIR/s28.md" 2>/dev/null
  check "Test 28n: a missing merged document never fails the caller" "0" "$?"
else
  echo "⏭️  renumber-suggested-fixes.sh or jq missing — skipping Test 28"
fi

# The remap only matters when the splice actually replaced the orchestrator
# numbering, so assert the call site as well as the unit: a refactor that drops
# it restores silently-wrong cross-references with no unit test able to see it.
if [ -f "$AGG_SH" ]; then
  check "Test 28o: aggregation invokes the remapper" "1" \
    "$(grep -cF 'lib/renumber-suggested-fixes.sh' "$AGG_SH" || true)"
  check "Test 28p: it runs before the note that describes the reconciled section" "1" \
    "$(awk '/lib\/renumber-suggested-fixes\.sh/{r=NR} /lib\/annotate-suggested-fixes\.sh/{if (r && NR > r) {print 1; exit}}' "$AGG_SH")"
fi

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
SUITE_COMPLETED=1
[ "$fail" -eq 0 ]
