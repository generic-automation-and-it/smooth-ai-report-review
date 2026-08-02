#!/bin/bash
set -uo pipefail

# Test script for lib/number-holistic-items.sh (LADR-063).
#
# The input is model-authored prose, so every assertion here is about a
# structural boundary the script must respect no matter what the model wrote:
# which bullets are items, which are template scaffolding, and — most
# importantly — that a departure from the template degrades to "unnumbered"
# rather than to a mangled or truncated holistic analysis. The posted review is
# the only durable record of a run; losing it to a numbering pass would be a
# much worse trade than never numbering at all.

echo "=========================================="
echo "Testing holistic item numbering (LADR-063)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUMBER_SH="$SCRIPT_DIR/lib/number-holistic-items.sh"

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

[ -f "$NUMBER_SH" ] || { echo "❌ missing $NUMBER_SH"; exit 1; }

# A holistic section in the shape both templates produce: scaffolding bullets
# above the anchor, severity subsections with placeholders and real items below.
write_fixture() {
  cat > "$1" <<'FIXTURE'
## 🔄 Holistic Cross-Chunk Analysis

**Purpose:** This analysis views the PR as a unified whole.

**What we looked for:**
- Architectural patterns or anti-patterns across chunks
- Consistency issues between different parts of the codebase

**Cross-Chunk Issues Found:**

🔴 **Critical Issues**
None found

🟠 **High Priority Issues**

- The retry helper added in chunk 2 is never called from the handler in chunk 4.
  - Follow-on detail that belongs to the item above.

🟡 **Medium Priority Issues**

- Two chunks introduce the same constant with different values.

🔵 **Low Priority / Nitpicks**

- N/A

**Additional Analysis:**
- **Consistency:** The naming drifts between the two new modules.
- **Dependency Injection Analysis:** Not applicable.

**Overall Assessment:** One integration gap worth a follow-up.
FIXTURE
}

# --- Test 1: items are numbered, scaffolding is not --------------------------
f="$TMP_DIR/standard.md"
write_fixture "$f"
before_lines="$(wc -l < "$f")"
bash "$NUMBER_SH" "$f"

check "Test 1a: three real items numbered" "3" \
  "$(grep -cE '^- \*\*#H[0-9]+\*\* ' "$f")"
check "Test 1b: numbering is sequential from 1" "1,2,3" \
  "$(grep -oE '#H[0-9]+' "$f" | sed 's/#H//' | tr '\n' ',' | sed 's/,$//')"
check "Test 1c: the What-we-looked-for checklist is untouched" "0" \
  "$(awk '/^\*\*Cross-Chunk Issues Found/{exit} /^- \*\*#H/{c++} END{print c+0}' "$f")"
check "Test 1d: line count is preserved" "$before_lines" "$(wc -l < "$f")"

# --- Test 2: placeholders and continuations stay unnumbered ------------------
check "Test 2a: a bare N/A bullet is not numbered" "0" \
  "$(grep -c '^- \*\*#H[0-9]*\*\* N/A' "$f" || true)"
check "Test 2b: 'Not applicable' analysis line is not numbered" "0" \
  "$(grep -c '#H[0-9]*\*\* \*\*Dependency Injection' "$f" || true)"
check "Test 2c: indented continuation bullet is not numbered" "0" \
  "$(grep -cE '^[[:space:]]+- \*\*#H' "$f" || true)"
check "Test 2d: substantive analysis line IS numbered" "1" \
  "$(grep -c '#H[0-9]*\*\* \*\*Consistency:' "$f" || true)"

# --- Test 3: idempotence -----------------------------------------------------
# aggregate-reviews.sh calls this once, but a retry or a future second call must
# not produce `#H1 #H1` or restart the sequence.
cp "$f" "$TMP_DIR/once.md"
bash "$NUMBER_SH" "$f"
check "Test 3: re-running is a no-op" "$(cat "$TMP_DIR/once.md")" "$(cat "$f")"

# --- Test 4: no anchor → nothing is touched ----------------------------------
# The anchor is the only structural promise the template makes. Without it the
# script cannot tell an item from a checklist entry, so it must do nothing.
noanchor="$TMP_DIR/noanchor.md"
printf '## 🔄 Holistic Cross-Chunk Analysis\n\n- freeform bullet\n- another\n' > "$noanchor"
cp "$noanchor" "$TMP_DIR/noanchor.orig"
bash "$NUMBER_SH" "$noanchor"
check "Test 4: file without the anchor is left byte-identical" \
  "$(cat "$TMP_DIR/noanchor.orig")" "$(cat "$noanchor")"

# --- Test 5: fenced blocks are not rewritten ---------------------------------
fenced="$TMP_DIR/fenced.md"
cat > "$fenced" <<'FENCED'
**Cross-Chunk Issues Found:**

🟡 **Medium Priority Issues**

- A real item.

```markdown
- An example bullet inside a fence.
```

- Another real item.
FENCED
bash "$NUMBER_SH" "$fenced"
check "Test 5a: bullet inside a fence is untouched" "1" \
  "$(grep -c '^- An example bullet inside a fence.$' "$fenced")"
check "Test 5b: real items either side of the fence are numbered" "2" \
  "$(grep -cE '^- \*\*#H[0-9]+\*\* ' "$fenced")"

# --- Test 6: degradation -----------------------------------------------------
bash "$NUMBER_SH" "$TMP_DIR/does-not-exist.md"
check "Test 6a: missing file exits 0" "0" "$?"
: > "$TMP_DIR/empty.md"
bash "$NUMBER_SH" "$TMP_DIR/empty.md"
check "Test 6b: empty file exits 0" "0" "$?"
check "Test 6c: empty file stays empty" "0" "$(wc -c < "$TMP_DIR/empty.md" | tr -d ' ')"
bash "$NUMBER_SH"
check "Test 6d: no argument exits 0" "0" "$?"

# --- Test 7: the aggregation call site still exists --------------------------
# The numbering is invisible when it does not run — no error, no log line, just
# a review that looks like the pre-LADR-063 one. Pin the wiring.
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"
check "Test 7a: aggregate-reviews.sh invokes the numberer" "1" \
  "$(grep -c 'number-holistic-items.sh' "$AGG_SH" || true)"
check "Test 7b: it runs after balance_fences on the detailed file" "1" \
  "$(awk '/^balance_fences ci_temp\/pr_summary_detailed.md/{seen=1; next} seen && /number-holistic-items.sh/{print 1; exit}' "$AGG_SH")"

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Holistic numbering tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Holistic numbering tests passed ($pass checks)"
echo "=========================================="
