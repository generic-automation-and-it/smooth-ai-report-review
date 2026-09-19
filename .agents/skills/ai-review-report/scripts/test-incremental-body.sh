#!/usr/bin/env bash
# Tests for the LADR-073 incremental-body strip in aggregate-reviews.sh.
#
# An incremental review drops the two narrative overview sections (`## 📋 Overall
# Summary`, `## ✅ Positive Highlights`) from the orchestrator's summary before it
# is concatenated into the posted body. The awk that does it is the riskiest part
# of LADR-073: it deletes a range from a model-authored document, and the sections
# it must NOT touch include `## 🔍 Issues Summary` — the string
# `select-ai-analyse-artifact.sh` (LADR-042) classifies actionable artifacts on.
# Deleting that section by accident silently decommissions the incremental
# auto-fix loop, and no posted-body assertion would notice.
#
# The awk program is EXTRACTED from aggregate-reviews.sh, never re-typed, so any
# drift in the real strip fails here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGG="$SCRIPT_DIR/aggregate-reviews.sh"

pass=0
fail=0

echo "=========================================="
echo "Testing the incremental-body strip (LADR-073)"
echo "=========================================="
echo ""

if [ ! -f "$AGG" ]; then
  echo "❌ aggregate-reviews.sh not found at $AGG"
  exit 1
fi

# Extract the strip program: everything between the `  awk '` line and the line
# that redirects into pr_summary_main.incremental.md. Matching `  awk '` exactly
# (indent included) keeps it from colliding with the deeper-indented
# Issues-Summary splice awks earlier in the file. The quote char is built with
# sprintf so this extractor itself needs no nested quoting.
STRIP_AWK=$(awk '
  BEGIN { q = sprintf("%c", 39) }
  $0 == "  awk " q { buf = ""; collecting = 1; next }
  collecting && index($0, "pr_summary_main.incremental.md") { printf "%s", buf; exit }
  collecting { buf = buf $0 "\n" }
' "$AGG")

if [ -z "$STRIP_AWK" ]; then
  echo "❌ Could not extract the incremental strip awk from aggregate-reviews.sh"
  exit 1
fi

strip() { printf '%s\n' "$1" | awk "$STRIP_AWK"; }

check_absent() {
  local label="$1" out="$2" needle="$3"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "❌ $label: '$needle' should have been stripped"
    fail=$((fail + 1))
  else
    echo "✅ $label: '$needle' stripped"
    pass=$((pass + 1))
  fi
}

check_present() {
  local label="$1" out="$2" needle="$3"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "✅ $label: '$needle' preserved"
    pass=$((pass + 1))
  else
    echo "❌ $label: '$needle' should have been preserved"
    fail=$((fail + 1))
  fi
}

# ── Test 1: the two overview sections go, everything else stays ──────────────
SUMMARY_FULL='## 📋 Overall Summary
This PR refactors the review gate.

### Scope
Three files.

## ✅ Positive Highlights
- Good test coverage.

## 🔍 Issues Summary
1. **Critical** something broke.

## 📝 Suggested Fixes
Change the thing.

## 🎯 Recommendation
**Decision:** REQUEST CHANGES

**MACHINE_READABLE_ACTION:** REQUEST_CHANGES'

OUT="$(strip "$SUMMARY_FULL")"
echo "Test 1: the two overview sections are dropped, the load-bearing ones kept"
check_absent  "Test 1" "$OUT" '## 📋 Overall Summary'
check_absent  "Test 1" "$OUT" 'This PR refactors the review gate.'
check_absent  "Test 1" "$OUT" '## ✅ Positive Highlights'
check_absent  "Test 1" "$OUT" 'Good test coverage.'
# A nested heading inside a dropped section goes with it (level-2 range, LADR-073).
check_absent  "Test 1" "$OUT" '### Scope'
check_present "Test 1" "$OUT" '## 🔍 Issues Summary'
check_present "Test 1" "$OUT" '## 📝 Suggested Fixes'
check_present "Test 1" "$OUT" '## 🎯 Recommendation'
check_present "Test 1" "$OUT" 'MACHINE_READABLE_ACTION'
echo ""

# ── Test 2: a fenced `## 📋 Overall Summary` must not open a strip range ─────
# The aggregation prompt tells the model its report must contain the literal
# heading, so a review that quotes the contract inside a code block is expected
# prose — not a section boundary. A fence-blind scan would open a range there and
# delete the rest of Suggested Fixes.
SUMMARY_FENCED_START='## 🔍 Issues Summary
1. **Low** nothing much.

## 📝 Suggested Fixes
The aggregation prompt requires:

```
## 📋 Overall Summary
## ✅ Positive Highlights
```

KEEP_ME_AFTER_FENCE

## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** COMMENT'

OUT="$(strip "$SUMMARY_FENCED_START")"
echo "Test 2: a fenced heading does not open a strip range"
check_present "Test 2" "$OUT" 'KEEP_ME_AFTER_FENCE'
check_present "Test 2" "$OUT" '## 🎯 Recommendation'
check_present "Test 2" "$OUT" 'MACHINE_READABLE_ACTION'
check_present "Test 2" "$OUT" '## 📝 Suggested Fixes'
echo ""

# ── Test 3: a fenced heading inside a dropped section must not close it ──────
SUMMARY_FENCED_END='## ✅ Positive Highlights
LEAK_ME_NOT_ONE

```
## 🎯 Recommendation
```

LEAK_ME_NOT_TWO

## 🔍 Issues Summary
1. **Medium** real finding.'

OUT="$(strip "$SUMMARY_FENCED_END")"
echo "Test 3: a fenced heading inside a dropped section does not close it early"
check_absent  "Test 3" "$OUT" 'LEAK_ME_NOT_ONE'
check_absent  "Test 3" "$OUT" 'LEAK_ME_NOT_TWO'
check_present "Test 3" "$OUT" '## 🔍 Issues Summary'
check_present "Test 3" "$OUT" 'real finding'
echo ""

# ── Test 4: tilde fences behave like backtick fences ─────────────────────────
SUMMARY_TILDE='## 📝 Suggested Fixes
~~~
## 📋 Overall Summary
~~~
KEEP_ME_TILDE

## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** APPROVE'

OUT="$(strip "$SUMMARY_TILDE")"
echo "Test 4: ~~~ fences are honoured too"
check_present "Test 4" "$OUT" 'KEEP_ME_TILDE'
check_present "Test 4" "$OUT" 'MACHINE_READABLE_ACTION'
echo ""

# ── Test 5: a summary with neither heading passes through unchanged ──────────
# The orchestrator-failure fallback template and the LADR-055 splice paths can
# both produce a summary missing one or both headings; the strip must be a no-op
# there, not a truncation.
SUMMARY_NO_OVERVIEW='## 🔍 Issues Summary
1. **High** something.

## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** REQUEST_CHANGES'

OUT="$(strip "$SUMMARY_NO_OVERVIEW")"
echo "Test 5: a summary without the overview headings is unchanged"
if [ "$OUT" = "$SUMMARY_NO_OVERVIEW" ]; then
  echo "✅ Test 5: byte-identical passthrough"
  pass=$((pass + 1))
else
  echo "❌ Test 5: passthrough altered the summary"
  fail=$((fail + 1))
fi
echo ""

# ── Test 6: the strip's two guards ───────────────────────────────────────────
# A full review's body must stay byte-identical to pre-LADR-073, so the awk must
# sit inside a `REVIEW_TYPE = "incremental"` guard. It must ALSO sit inside an
# `agg_ok` guard: on the orchestrator-failure fallback, `## 📋 Overall Summary`
# carries the only explanation that summary generation failed, so stripping it
# leaves an unexplained degraded report regardless of the deterministic verdict.
echo "Test 6: the strip is guarded on REVIEW_TYPE = incremental AND agg_ok"
GUARD_LINE=$(grep -B 40 'pr_summary_main\.incremental\.md' "$AGG" \
  | grep -F 'REVIEW_TYPE" = "incremental"' | tail -1)
if printf '%s' "$GUARD_LINE" | grep -qF 'REVIEW_TYPE" = "incremental"'; then
  echo "✅ Test 6: strip guarded by REVIEW_TYPE = incremental"
  pass=$((pass + 1))
else
  echo "❌ Test 6: no REVIEW_TYPE = incremental guard found above the strip"
  fail=$((fail + 1))
fi
if printf '%s' "$GUARD_LINE" | grep -qF 'agg_ok'; then
  echo "✅ Test 6: strip guarded by agg_ok (fallback summary keeps its diagnosis)"
  pass=$((pass + 1))
else
  echo "❌ Test 6: strip is not guarded by agg_ok — the fallback template's Overall Summary would be stripped"
  fail=$((fail + 1))
fi
echo ""

# ── Test 7: the header split — `Reviewed in:` both types, `Model:` full only ──
# `**Reviewed in:**` is coverage information (how much of the delta was actually
# reviewed) and is the one header line an incremental reader cannot reconstruct:
# the coverage banner only prints when a chunk failed, so a healthy incremental
# would otherwise carry no chunk count anywhere. `**Model:**` is recap and stays
# full-only. Asserted on the source because the two lines sit adjacent and are
# trivially re-merged into one guarded heredoc by a later edit.
echo "Test 7: Reviewed-in is emitted for both review types, Model only for full"
REVIEWED_GUARD=$(grep -B 6 '^\*\*Reviewed in:\*\*' "$AGG" | grep -cF 'REVIEW_TYPE" != "incremental"')
MODEL_GUARD=$(grep -B 3 '^\*\*Model:\*\*' "$AGG" | grep -cF 'REVIEW_TYPE" != "incremental"')

if [ "$REVIEWED_GUARD" -eq 0 ]; then
  echo "✅ Test 7: **Reviewed in:** is not behind a full-only guard"
  pass=$((pass + 1))
else
  echo "❌ Test 7: **Reviewed in:** sits behind a REVIEW_TYPE != incremental guard — incrementals would carry no chunk count"
  fail=$((fail + 1))
fi

if [ "$MODEL_GUARD" -ge 1 ]; then
  echo "✅ Test 7: **Model:** is full-only"
  pass=$((pass + 1))
else
  echo "❌ Test 7: **Model:** is no longer behind a REVIEW_TYPE != incremental guard"
  fail=$((fail + 1))
fi
echo ""

echo "=========================================="
echo "Passed: $pass   Failed: $fail"
echo "=========================================="
[ "$fail" -eq 0 ] || exit 1
