#!/bin/bash
set -uo pipefail

# Offline regression test for LADR-083 (Skip Areas bullets never reached a prompt)
# and LADR-084 (the LADR-082 retry re-ran an identical budget split).
#
# Part 1 exercises lib/extract-review-notes.sh directly: the Skip Areas bullets
# must survive, the heading must survive (the chunk prompt's rule names it by
# string), unrelated `##` sections must NOT leak, and a body with no Skip Areas
# section must produce byte-identical output to the pre-LADR-083 inline awk.
# Part 2 greps the two call sites and the retry sweep so the fixed shapes cannot
# be quietly reverted — same guard style as test-diff-base.sh 13-15.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/extract-review-notes.sh"
CHUNKS="${SCRIPT_DIR}/review-in-chunks.sh"
AGG="${SCRIPT_DIR}/aggregate-reviews.sh"

FAILURES=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }

echo "=========================================="
echo "Testing review-notes extraction (LADR-083/084)"
echo "=========================================="
echo ""

# The section ORDER here matters: Skip Areas sits BEFORE AI Review Notes, which is
# the order `ai-review` writes and the exact order the old awk silently dropped.
BODY_FULL='## Description

Some description text.

## Testing

- ran the suite

## Skip Areas / Known Issues

- src/Host/Program.cs:82 — middleware ordering false positive — **skip reason:** L2 tests prove tokens reach handlers.
- scripts/legacy.sh:10 — dead path — **skip reason:** deleted next release.

## AI Review Notes

**Focus Areas:**

- Verify the thing.

### AI Review Response — review 123

| # | Decision | Finding | Response |
|---|---|---|---|
| 1 | SKIP | middleware ordering | false positive |'

BODY_NO_SKIPS='## Description

text

## AI Review Notes

**Focus Areas:**

- Verify the thing.'

BODY_ONLY_SKIPS='## Description

text

## Skip Areas / Known Issues

- foo.py:1 — thing — **skip reason:** intentional.'

BODY_NEITHER='## Description

text

## Testing

- none'

echo "── Part 1: lib/extract-review-notes.sh ──"

OUT_FULL="$(printf '%s\n' "$BODY_FULL" | bash "$LIB")"

# 1
if printf '%s\n' "$OUT_FULL" | grep -q 'Program.cs:82'; then
  pass "1. Skip Areas bullet reaches the extracted notes"
else
  fail "1. Skip Areas bullet MISSING — this is the LADR-083 defect"
fi
# 2
if printf '%s\n' "$OUT_FULL" | grep -q 'legacy.sh:10'; then
  pass "2. every Skip Areas bullet is captured, not just the first"
else
  fail "2. second Skip Areas bullet dropped"
fi
# 3 — the chunk prompt's rule references the literal string, so it must be present.
if printf '%s\n' "$OUT_FULL" | grep -q 'Skip Areas'; then
  pass "3. a heading containing the literal 'Skip Areas' survives"
else
  fail "3. no 'Skip Areas' string — the prompt rule loses its referent"
fi
# 4 — demoted so it nests under the prompt's own '## 📝 AI REVIEW NOTES'.
if printf '%s\n' "$OUT_FULL" | grep -q '^### Skip Areas'; then
  pass "4. Skip Areas heading is demoted to ###"
else
  fail "4. Skip Areas heading is not '### '-level"
fi
# 5 — adjacent to the rule that names it.
if [ "$(printf '%s\n' "$OUT_FULL" | grep -n 'Skip Areas' | head -1 | cut -d: -f1)" -gt \
     "$(printf '%s\n' "$OUT_FULL" | grep -n 'Focus Areas' | head -1 | cut -d: -f1)" ]; then
  pass "5. Skip Areas is emitted AFTER the notes body, regardless of body order"
else
  fail "5. Skip Areas emitted before the notes body"
fi
# 6
if printf '%s\n' "$OUT_FULL" | grep -q 'AI Review Response'; then
  pass "6. the ### AI Review Response table is still captured"
else
  fail "6. AI Review Response table lost"
fi
# 7 — sibling sections must not leak in.
if printf '%s\n' "$OUT_FULL" | grep -qE 'Some description text|ran the suite'; then
  fail "7. unrelated ## sections leaked into the notes"
else
  pass "7. unrelated ## sections (Description, Testing) do not leak"
fi
# 8 — no-Skip-Areas bodies must be byte-identical to the old inline awk.
OUT_NO_SKIPS="$(printf '%s\n' "$BODY_NO_SKIPS" | bash "$LIB")"
LEGACY="$(printf '%s\n' "$BODY_NO_SKIPS" \
  | awk '/^## AI Review Notes/{flag=1; next} /^## /{flag=0} flag' \
  | sed '/^<!--/,/-->$/d' | sed '/^$/d')"
if [ "$OUT_NO_SKIPS" = "$LEGACY" ]; then
  pass "8. bodies without Skip Areas are byte-identical to the pre-LADR-083 awk"
else
  fail "8. behaviour changed for bodies without Skip Areas"
fi
# 9 — Skip Areas alone must still be delivered (old code required AI Review Notes).
OUT_ONLY="$(printf '%s\n' "$BODY_ONLY_SKIPS" | bash "$LIB")"
if printf '%s\n' "$OUT_ONLY" | grep -q 'foo.py:1'; then
  pass "9. Skip Areas alone is extracted with no AI Review Notes section present"
else
  fail "9. Skip Areas dropped when AI Review Notes is absent"
fi
# 10
OUT_NEITHER="$(printf '%s\n' "$BODY_NEITHER" | bash "$LIB")"
if [ -z "$OUT_NEITHER" ]; then
  pass "10. neither section present → empty output (caller omits the prompt block)"
else
  fail "10. output should be empty when neither section is present"
fi
# 11 — HTML comment stripping carried over from the call sites.
OUT_COMMENT="$(printf '## AI Review Notes\n\n<!--\nhidden\n-->\n- visible\n' | bash "$LIB")"
if printf '%s\n' "$OUT_COMMENT" | grep -q 'visible' && ! printf '%s\n' "$OUT_COMMENT" | grep -q 'hidden'; then
  pass "11. HTML comments are still stripped"
else
  fail "11. HTML comment stripping regressed"
fi
# 12 — always exit 0; an extraction failure must never fail a review.
printf '%s\n' "$BODY_FULL" | bash "$LIB" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  pass "12. lib exits 0"
else
  fail "12. lib exited non-zero"
fi
# 13 — tolerate a bare '## Skip Areas' heading with no trailing words.
OUT_BARE="$(printf '## Skip Areas\n\n- bar.py:2 — thing — **skip reason:** x.\n' | bash "$LIB")"
if printf '%s\n' "$OUT_BARE" | grep -q 'bar.py:2'; then
  pass "13. a bare '## Skip Areas' heading is matched"
else
  fail "13. bare '## Skip Areas' heading not matched"
fi

echo ""
echo "── Part 2: call sites cannot drift back ──"

# 14/15 — both consumers must go through the lib, not a local awk.
for f in "$CHUNKS" "$AGG"; do
  n="$(basename "$f")"
  if grep -q 'lib/extract-review-notes.sh' "$f"; then
    pass "${n} calls lib/extract-review-notes.sh"
  else
    fail "${n} does not call lib/extract-review-notes.sh"
  fi
done
# 16/17 — the narrow awk must not come back in either file.
for f in "$CHUNKS" "$AGG"; do
  n="$(basename "$f")"
  if grep -q "awk '/\^## AI Review Notes/" "$f"; then
    fail "${n} still carries the narrow inline awk (LADR-083 regression)"
  else
    pass "${n} no longer carries the narrow inline awk"
  fi
done
# 18 — the aggregation prompt needs the skip rule too (holistic 🔴/🟠 blocks alone).
if grep -q 'Skip Areas' "$AGG"; then
  pass "aggregate-reviews.sh prompt carries the Skip Areas out-of-scope rule"
else
  fail "aggregate-reviews.sh prompt has no Skip Areas rule"
fi
# 19 — chunk prompt rule still present.
if grep -q 'Skip Areas' "$CHUNKS"; then
  pass "review-in-chunks.sh prompt still carries the Skip Areas out-of-scope rule"
else
  fail "review-in-chunks.sh lost the Skip Areas rule"
fi
# 20/21/22 — LADR-084: the retry must not reuse attempt 1's split.
if grep -q 'export CHUNK_RETRY_ATTEMPT=1' "$CHUNKS"; then
  pass "retry sweep sets CHUNK_RETRY_ATTEMPT=1"
else
  fail "retry sweep does not set CHUNK_RETRY_ATTEMPT (LADR-084 regression)"
fi
if grep -q 'unset CHUNK_RETRY_ATTEMPT' "$CHUNKS"; then
  pass "retry mode is unset after the sweep"
else
  fail "retry mode leaks past the sweep"
fi
if grep -q 'CHUNK_RETRY_ATTEMPT:-0' "$CHUNKS"; then
  pass "review_chunk reads CHUNK_RETRY_ATTEMPT to collapse the split"
else
  fail "review_chunk never reads CHUNK_RETRY_ATTEMPT"
fi
# 23 — the collapse must zero the secondary reserve, or the split still applies.
if grep -A3 'CHUNK_RETRY_ATTEMPT:-0' "$CHUNKS" | grep -q '_secondary_budget=0'; then
  pass "retry collapse zeroes the secondary reserve"
else
  fail "retry collapse does not zero the secondary reserve"
fi

echo ""
echo "── Part 3: LADR-084 collapse evaluated from the real source ──"

# Greps prove the fragment is present; this proves it BEHAVES. The block is cut
# out of the shipped script by its own markers and eval'd against synthetic
# budgets, so a future edit that keeps the marker but breaks the arithmetic (or
# inverts the condition) fails here rather than in CI on somebody's PR.
_collapse_block="$(awk '/CHUNK_RETRY_ATTEMPT:-0/{f=1} f{print} f&&/^  fi$/{exit}' "$CHUNKS")"
if [ -z "$_collapse_block" ]; then
  fail "24. could not extract the LADR-084 collapse block from review-in-chunks.sh"
else
  # Retry mode ON: primary must take the whole budget, secondary must be 0.
  _out="$(
    CHUNK_RETRY_ATTEMPT=1 _chunk_timeout=868 _primary_budget=600 _secondary_budget=268 chunk_num=2 \
    bash -c "$(printf '%s\n' "$_collapse_block" | sed 's/^  //')"'
'"echo \"\$_primary_budget \$_secondary_budget\"" 2>/dev/null | tail -1
  )"
  if [ "$_out" = "868 0" ]; then
    pass "24. retry mode: 600/268 split collapses to 868s primary / 0 secondary"
  else
    fail "24. retry mode produced '$_out', expected '868 0'"
  fi
  # Retry mode OFF: the LADR-081 split must survive untouched.
  _out2="$(
    _chunk_timeout=868 _primary_budget=600 _secondary_budget=268 chunk_num=2 \
    bash -c "$(printf '%s\n' "$_collapse_block" | sed 's/^  //')"'
'"echo \"\$_primary_budget \$_secondary_budget\"" 2>/dev/null | tail -1
  )"
  if [ "$_out2" = "600 268" ]; then
    pass "25. normal mode: the LADR-081 split is left untouched"
  else
    fail "25. normal mode produced '$_out2', expected '600 268'"
  fi
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "=========================================="
  echo "Review-notes extraction tests FAILED (${FAILURES})"
  echo "=========================================="
  exit 1
fi
echo "=========================================="
echo "Review-notes extraction tests passed"
echo "=========================================="
