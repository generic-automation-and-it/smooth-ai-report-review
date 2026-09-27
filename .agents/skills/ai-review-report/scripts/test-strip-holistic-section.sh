#!/bin/bash
set -uo pipefail

# Test script for lib/strip-holistic-section.sh (LADR-100).
#
# The review has one overview — the Issues Summary — and no holistic section.
# The prompt no longer asks for one; this lib removes one a model writes anyway,
# by the old marker or by the heading, without touching anything else. Offline.

echo "=========================================="
echo "Testing holistic section removal (LADR-100)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIP="$SCRIPT_DIR/lib/strip-holistic-section.sh"
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"
SYNC_SH="$SCRIPT_DIR/lib/sync-recommendation-from-findings.sh"

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

[ -f "$STRIP" ] || { echo "❌ missing $STRIP"; exit 1; }

MAIN='## 📋 Overall Summary
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

**Cross-Chunk Issues Found:**

🟠 **High Priority Issues**
- **2) [VERIFIED]** The config written in chunk 1 is never read by chunk 3.

**Overall Assessment:** One integration gap.'

headings() { grep '^## ' "$1" | sed 's/^## //' | paste -sd, -; }
EXPECTED_HEADINGS="📋 Overall Summary,🔍 Issues Summary,📝 Suggested Fixes,🎯 Recommendation"

# --- 1. the old marker shape --------------------------------------------------
printf '%s\n\n---\nDETAILED_SECTION_MARKER\n---\n\n%s\n' "$MAIN" "$HOLISTIC" > "$TMP_DIR/marker.md"
bash "$STRIP" "$TMP_DIR/marker.md" "$TMP_DIR/m1.md"
check "Test 1a: marker → the holistic section and the marker are gone" "0|0" \
  "$(grep -c 'Holistic\|never read by chunk 3' "$TMP_DIR/m1.md" || true)|$(grep -c 'DETAILED_SECTION_MARKER' "$TMP_DIR/m1.md" || true)"
check "Test 1b: marker → the main body is intact and ends on the verdict, not a stray rule" "$EXPECTED_HEADINGS|**MACHINE_READABLE_ACTION:** REQUEST_CHANGES" \
  "$(headings "$TMP_DIR/m1.md")|$(tail -1 "$TMP_DIR/m1.md")"

# --- 2. heading only (the shape most models actually wrote) ------------------
printf '%s\n\n---\n\n%s\n' "$MAIN" "$HOLISTIC" > "$TMP_DIR/heading.md"
bash "$STRIP" "$TMP_DIR/heading.md" "$TMP_DIR/m2.md"
check "Test 2: heading only → same result as the marker path" "same" \
  "$(cmp -s "$TMP_DIR/m1.md" "$TMP_DIR/m2.md" && echo same || echo differs)"

# --- 3. a main-body heading after the section ends it -------------------------
printf '## 🔍 Issues Summary\nx\n\n%s\n\n## 🎯 Recommendation\n**MACHINE_READABLE_ACTION:** APPROVE\n' "$HOLISTIC" > "$TMP_DIR/mid.md"
bash "$STRIP" "$TMP_DIR/mid.md" "$TMP_DIR/m3.md"
check "Test 3: the Recommendation after a holistic section is kept" "🔍 Issues Summary,🎯 Recommendation|1|0" \
  "$(headings "$TMP_DIR/m3.md")|$(grep -c 'MACHINE_READABLE_ACTION:\*\* APPROVE' "$TMP_DIR/m3.md")|$(grep -c 'never read by chunk 3' "$TMP_DIR/m3.md" || true)"

# --- 4. no holistic section → unchanged ---------------------------------------
printf '%s\n' "$MAIN" > "$TMP_DIR/none.md"
bash "$STRIP" "$TMP_DIR/none.md" "$TMP_DIR/m4.md"
check "Test 4: no holistic section → the summary is byte-identical" "same" \
  "$(cmp -s "$TMP_DIR/none.md" "$TMP_DIR/m4.md" && echo same || echo differs)"

# --- 5. fences ---------------------------------------------------------------
# A heading or marker inside a code example is not a section.
printf '## 🔍 Issues Summary\n````markdown\n```markdown\n## 🔄 Holistic Cross-Chunk Analysis\nDETAILED_SECTION_MARKER\n```\n````\n\n## 🎯 Recommendation\nok\n' > "$TMP_DIR/fence.md"
bash "$STRIP" "$TMP_DIR/fence.md" "$TMP_DIR/m5.md"
check "Test 5a: a heading and marker inside a nested fence are left alone" "same" \
  "$(cmp -s "$TMP_DIR/fence.md" "$TMP_DIR/m5.md" && echo same || echo differs)"
# A fenced example inside a real holistic section goes with it, including an
# example main heading that must not end the section early.
printf '## 🎯 Recommendation\nok\n\n## 🔄 Holistic Cross-Chunk Analysis\n- x\n````markdown\n```markdown\n## 🔍 Issues Summary\n```\n````\n- still holistic\n' > "$TMP_DIR/fence2.md"
bash "$STRIP" "$TMP_DIR/fence2.md" "$TMP_DIR/m5b.md"
check "Test 5b: an example main heading inside the section does not end it" "🎯 Recommendation|0" \
  "$(headings "$TMP_DIR/m5b.md")|$(grep -c 'still holistic' "$TMP_DIR/m5b.md" || true)"

# --- 6. degradation -----------------------------------------------------------
bash "$STRIP" "$TMP_DIR/missing.md" "$TMP_DIR/m6.md"
check "Test 6a: a missing input exits 0 with an empty output" "0|0" "$?|$(wc -c < "$TMP_DIR/m6.md" | tr -d ' ')"
bash "$STRIP"
check "Test 6b: no arguments exits 0" "0" "$?"

# --- 7. wiring ----------------------------------------------------------------
check "Test 7a: aggregation strips through the lib, before the fences are balanced" "1" \
  "$(awk '/lib\/strip-holistic-section.sh/{s=NR} /^balance_fences ci_temp\/pr_summary_main.md/{print (s && s < NR) ? 1 : 0; exit}' "$AGG_SH")"
check "Test 7b: the prompt no longer asks for a holistic section or the marker" "0|0|1" \
  "$(grep -c '^## 🔄 Holistic Cross-Chunk Analysis' "$AGG_SH" || true)|$(grep -c '^DETAILED_SECTION_MARKER' "$AGG_SH" || true)|$(grep -c 'Do not add a separate cross-chunk or holistic section (LADR-100)' "$AGG_SH")"
check "Test 7c: the sync takes no holistic input" "0" \
  "$(grep -c 'holistic_blocking\|\${3:-}' "$SYNC_SH" || true)"

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Holistic removal tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Holistic removal tests passed ($pass checks)"
echo "=========================================="
