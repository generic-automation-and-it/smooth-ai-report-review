#!/bin/bash
set -uo pipefail

# Test script for lib/holistic-section.sh (LADR-099).
#
# The orchestrator is asked to put DETAILED_SECTION_MARKER before its holistic
# section and mostly does not (21 of 22 reviews on this repo). Every case here
# is about where the holistic section ends up — and, the load-bearing one, that
# the Recommendation sync still sees a holistic Critical/High when the marker is
# missing. Offline: no model, no network.

echo "=========================================="
echo "Testing holistic section split/placement (LADR-099)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS="$SCRIPT_DIR/lib/holistic-section.sh"
NUMBER_SH="$SCRIPT_DIR/lib/number-holistic-items.sh"
SYNC_SH="$SCRIPT_DIR/lib/sync-recommendation-from-findings.sh"
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    fail=$((fail + 1))
  fi
}

[ -f "$HS" ] || { echo "❌ missing $HS"; exit 1; }

HEAD_MAIN='## 📋 Overall Summary
Summary text.

## 🔍 Issues Summary

### 🟠 High Priority Issues
1) [VERIFIED] High: a finding — `a.sh:3`

## 📝 Suggested Fixes
None

## 🎯 Recommendation
**Decision:** REQUEST CHANGES
**MACHINE_READABLE_ACTION:** REQUEST_CHANGES'

HOLISTIC='## 🔄 Holistic Cross-Chunk Analysis

**Purpose:** This analysis views the PR as a unified whole.

**What we looked for:**
- Architectural patterns

**Cross-Chunk Issues Found:**

🔴 **Critical Issues**
None found.

🟠 **High Priority Issues**
- **2) [VERIFIED]** The config written in chunk 1 is never read by chunk 3.

**Overall Assessment:** One integration gap.'

# --- Test 1: the marker path --------------------------------------------------
printf '%s\n\n---\nDETAILED_SECTION_MARKER\n---\n\n%s\n' "$HEAD_MAIN" "$HOLISTIC" > "$TMP_DIR/marker.md"
bash "$HS" split "$TMP_DIR/marker.md" "$TMP_DIR/m1.md" "$TMP_DIR/h1.md"
check "Test 1a: marker → main body has no holistic heading" "0" \
  "$(grep -c 'Holistic Cross-Chunk' "$TMP_DIR/m1.md" || true)"
check "Test 1b: marker → main body keeps the Recommendation" "1" \
  "$(grep -c '^\*\*MACHINE_READABLE_ACTION:\*\* REQUEST_CHANGES' "$TMP_DIR/m1.md")"
check "Test 1c: marker line and its rules are gone from both halves" "0|0" \
  "$(grep -c 'DETAILED_SECTION_MARKER' "$TMP_DIR/m1.md" || true)|$(grep -c 'DETAILED_SECTION_MARKER' "$TMP_DIR/h1.md" || true)"
check "Test 1d: main body does not end in a stray rule" "**MACHINE_READABLE_ACTION:** REQUEST_CHANGES" \
  "$(tail -1 "$TMP_DIR/m1.md")"
check "Test 1e: holistic starts with its heading" "## 🔄 Holistic Cross-Chunk Analysis" \
  "$(head -1 "$TMP_DIR/h1.md")"
check "Test 1f: template scaffolding (Purpose / What we looked for) is dropped" "0|0" \
  "$(grep -c 'Purpose:' "$TMP_DIR/h1.md" || true)|$(grep -c 'Architectural patterns' "$TMP_DIR/h1.md" || true)"
check "Test 1g: the items and the assessment are kept" "1|1" \
  "$(grep -c 'never read by chunk 3' "$TMP_DIR/h1.md")|$(grep -c 'Overall Assessment' "$TMP_DIR/h1.md")"

# --- Test 2: no marker — the shape 21 of 22 reviews actually had -------------
printf '%s\n\n---\n\n%s\n' "$HEAD_MAIN" "$HOLISTIC" > "$TMP_DIR/nomarker.md"
bash "$HS" split "$TMP_DIR/nomarker.md" "$TMP_DIR/m2.md" "$TMP_DIR/h2.md"
check "Test 2a: no marker → the heading still splits the section out" "0|1" \
  "$(grep -c 'Holistic Cross-Chunk' "$TMP_DIR/m2.md" || true)|$(grep -c '^## 🔄 Holistic Cross-Chunk Analysis' "$TMP_DIR/h2.md")"
check "Test 2b: no marker → same holistic body as the marker path" "same" \
  "$(cmp -s "$TMP_DIR/h1.md" "$TMP_DIR/h2.md" && echo same || echo differs)"
check "Test 2c: no marker → no placeholder text anywhere" "0" \
  "$(cat "$TMP_DIR/m2.md" "$TMP_DIR/h2.md" | grep -c 'No holistic analysis section found' || true)"

# The reason this matters: the sync reads the holistic file for blockers.
printf '{"status":"complete","merged_chunks":[0],"findings":[{"severity":"medium"}],"pre_existing_findings":[],"suppressed_findings":[],"malformed_findings":0,"demoted_no_quote":0}' \
  > "$TMP_DIR/medium.json"
printf '## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** APPROVE\n' > "$TMP_DIR/rec.md"
bash "$NUMBER_SH" "$TMP_DIR/h2.md"
check "Test 2d: no marker → a holistic High still blocks through the sync" "request_changes" \
  "$(bash "$SYNC_SH" "$TMP_DIR/medium.json" "$TMP_DIR/rec.md" "$TMP_DIR/h2.md" 2>/dev/null)"
check "Test 2e: the model's own \`2)\` is replaced by \`H1)\`" "1|0" \
  "$(grep -c '^- \*\*H1)\*\* \*\*\[VERIFIED\]\*\* The config' "$TMP_DIR/h2.md")|$(grep -cE '\*\*2\)' "$TMP_DIR/h2.md" || true)"

# --- Test 3: holistic heading before the Recommendation ---------------------
printf '## 🔍 Issues Summary\nx\n\n%s\n\n## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** APPROVE\n' "$HOLISTIC" > "$TMP_DIR/mid.md"
bash "$HS" split "$TMP_DIR/mid.md" "$TMP_DIR/m3.md" "$TMP_DIR/h3.md"
check "Test 3a: a main-body heading after the section ends it" "1|0" \
  "$(grep -c '^## 🎯 Recommendation' "$TMP_DIR/m3.md")|$(grep -c 'Recommendation' "$TMP_DIR/h3.md" || true)"

# --- Test 4: neither anchor → no holistic section at all --------------------
printf '%s\n' "$HEAD_MAIN" > "$TMP_DIR/none.md"
bash "$HS" split "$TMP_DIR/none.md" "$TMP_DIR/m4.md" "$TMP_DIR/h4.md"
check "Test 4a: no anchor → holistic file is empty" "0" "$(wc -c < "$TMP_DIR/h4.md" | tr -d ' ')"
check "Test 4b: no anchor → main body is the input unchanged" "same" \
  "$(cmp -s "$TMP_DIR/none.md" "$TMP_DIR/m4.md" && echo same || echo differs)"

# --- Test 5: a heading inside a fence is not a heading ----------------------
printf '## 🔍 Issues Summary\n```markdown\n## 🔄 Holistic Cross-Chunk Analysis\nDETAILED_SECTION_MARKER\n```\n\n## 🎯 Recommendation\nok\n' > "$TMP_DIR/fence.md"
bash "$HS" split "$TMP_DIR/fence.md" "$TMP_DIR/m5.md" "$TMP_DIR/h5.md"
check "Test 5: fenced heading and marker are left in the main body" "same|0" \
  "$(cmp -s "$TMP_DIR/fence.md" "$TMP_DIR/m5.md" && echo same || echo differs)|$(wc -c < "$TMP_DIR/h5.md" | tr -d ' ')"

# Review 5331170285 finding 1: a three-backtick line inside a four-backtick
# example must not close the fence. With a bare toggle the example's
# Recommendation heading ended the holistic section, the High after it went to
# the main body, and the sync saw no blocker.
cat > "$TMP_DIR/nested.md" <<'NESTED'
## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** APPROVE

## 🔄 Holistic Cross-Chunk Analysis

**Cross-Chunk Issues Found:**

🟡 **Medium Priority Issues**
- The template example below shows the shape:

````markdown
```markdown
## 🎯 Recommendation
- example bullet
```
````

🟠 **High Priority Issues**
- The writer in chunk 1 and the reader in chunk 3 disagree on the key.

**Overall Assessment:** One blocker.
NESTED
bash "$HS" split "$TMP_DIR/nested.md" "$TMP_DIR/m5b.md" "$TMP_DIR/h5b.md"
check "Test 5b: a nested fence keeps its example heading inside the holistic section" "1|1" \
  "$(grep -c 'disagree on the key' "$TMP_DIR/h5b.md")|$(grep -c '^## 🎯 Recommendation' "$TMP_DIR/m5b.md")"
bash "$NUMBER_SH" "$TMP_DIR/h5b.md"
check "Test 5c: the holistic High after a nested fence still blocks through the sync" "request_changes" \
  "$(bash "$SYNC_SH" "$TMP_DIR/medium.json" "$TMP_DIR/rec.md" "$TMP_DIR/h5b.md" 2>/dev/null)"
check "Test 5d: the bullet inside the nested fence is not numbered; the real ones are" "0|2" \
  "$(grep -c 'H[0-9]*)\*\* example bullet' "$TMP_DIR/h5b.md" || true)|$(grep -cE '^- \*\*H[0-9]+\)\*\*' "$TMP_DIR/h5b.md")"
printf '## 🔍 Issues Summary\n````markdown\n```\n## not a heading\n```\n````\n\n## 🎯 Recommendation\nok\n' > "$TMP_DIR/p6.md"
bash "$HS" place "$TMP_DIR/p6.md" "$TMP_DIR/h1.md"
check "Test 5e: placement skips a heading inside a nested fence" "1" \
  "$(awk '/^## not a heading/{n=NR} /^## 🔄 Holistic/{print (n && NR > n) ? 1 : 0; exit}' "$TMP_DIR/p6.md")"

# --- Test 6: placement --------------------------------------------------------
cp "$TMP_DIR/m1.md" "$TMP_DIR/p1.md"
bash "$HS" place "$TMP_DIR/p1.md" "$TMP_DIR/h1.md"
check "Test 6a: placed directly after the Issues Summary, before Suggested Fixes" "🔍 Issues Summary,🔄 Holistic Cross-Chunk Analysis,📝 Suggested Fixes,🎯 Recommendation" \
  "$(grep '^## ' "$TMP_DIR/p1.md" | sed 's/^## //' | grep -v 'Overall Summary' | paste -sd, -)"
printf '## 📋 Overall Summary\nx\n\n## 🎯 Recommendation\nok\n' > "$TMP_DIR/p2.md"
bash "$HS" place "$TMP_DIR/p2.md" "$TMP_DIR/h1.md"
check "Test 6b: no Issues Summary → before the Recommendation" "📋 Overall Summary,🔄 Holistic Cross-Chunk Analysis,🎯 Recommendation" \
  "$(grep '^## ' "$TMP_DIR/p2.md" | sed 's/^## //' | paste -sd, -)"
printf '## 📋 Overall Summary\nx\n' > "$TMP_DIR/p3.md"
bash "$HS" place "$TMP_DIR/p3.md" "$TMP_DIR/h1.md"
check "Test 6c: neither → appended" "📋 Overall Summary,🔄 Holistic Cross-Chunk Analysis" \
  "$(grep '^## ' "$TMP_DIR/p3.md" | sed 's/^## //' | paste -sd, -)"
cp "$TMP_DIR/m1.md" "$TMP_DIR/p4.md"
bash "$HS" place "$TMP_DIR/p4.md" "$TMP_DIR/h4.md"
check "Test 6d: an empty holistic file changes nothing" "same" \
  "$(cmp -s "$TMP_DIR/m1.md" "$TMP_DIR/p4.md" && echo same || echo differs)"
printf '## 🔍 Issues Summary\n```\n## not a heading\n```\n\n## 🎯 Recommendation\nok\n' > "$TMP_DIR/p5.md"
bash "$HS" place "$TMP_DIR/p5.md" "$TMP_DIR/h1.md"
check "Test 6e: a fenced \`## \` line inside the Issues Summary does not end it" "1" \
  "$(awk '/^## not a heading/{n=NR} /^## 🔄 Holistic/{print (n && NR > n) ? 1 : 0; exit}' "$TMP_DIR/p5.md")"

# --- Test 7: degradation ------------------------------------------------------
bash "$HS" split "$TMP_DIR/missing.md" "$TMP_DIR/m7.md" "$TMP_DIR/h7.md"
check "Test 7a: missing input → empty outputs, exit 0" "0|0|0" \
  "$?|$(wc -c < "$TMP_DIR/m7.md" | tr -d ' ')|$(wc -c < "$TMP_DIR/h7.md" | tr -d ' ')"
bash "$HS" place "$TMP_DIR/missing.md" "$TMP_DIR/h1.md"
check "Test 7b: place on a missing main body exits 0" "0" "$?"
bash "$HS" bogus 2>/dev/null
check "Test 7c: unknown subcommand exits 0" "0" "$?"

# --- Test 8: wiring -----------------------------------------------------------
check "Test 8a: aggregation splits through the lib" "1" \
  "$(grep -c 'lib/holistic-section.sh" split' "$AGG_SH" || true)"
check "Test 8b: aggregation places through the lib, before the main body is posted" "1" \
  "$(awk '/lib\/holistic-section.sh" place/{p=NR} /^cat ci_temp\/pr_summary_main\.md >> ci_temp\/final_review\.md/{print (p && p < NR) ? 1 : 0; exit}' "$AGG_SH")"
check "Test 8c: the placeholder heading is gone" "0" \
  "$(grep -c 'No holistic analysis section found' "$AGG_SH" || true)"
check "Test 8d: the holistic file is no longer posted inside the details block" "0" \
  "$(grep -c '^cat ci_temp/pr_summary_detailed.md >> ci_temp/final_review.md' "$AGG_SH" || true)"
check "Test 8e: the prompt forbids restating chunk findings in the holistic section" "1" \
  "$(grep -c 'A finding a chunk review already reported belongs in the Issues Summary and nowhere in the holistic section' "$AGG_SH" || true)"
check "Test 8f: the prompt forbids model numbers in the holistic section" "1" \
  "$(grep -c 'Do NOT number the holistic items' "$AGG_SH" || true)"

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Holistic section tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Holistic section tests passed ($pass checks)"
echo "=========================================="
