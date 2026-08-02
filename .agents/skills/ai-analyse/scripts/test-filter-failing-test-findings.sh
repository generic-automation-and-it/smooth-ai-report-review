#!/bin/bash
# Offline regression coverage for filter-failing-test-findings.sh:
# verifies that failing-test findings are withheld, non-failing-test
# findings survive, and the withheld report is produced correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/lib/filter-failing-test-findings.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ── 1. Failing-test finding is withheld ──────────────────────────
input1='- 🟡 Medium Priority: FooTests.Bar is failing after this change
- 🟡 Medium Priority: Add a test for the empty-collection branch'

filtered1="$(printf '%s' "$input1" | bash "$HELPER" 2>/dev/null)"
[ "$filtered1" = '- 🟡 Medium Priority: Add a test for the empty-collection branch' ] || {
  echo "FAIL: failing-test finding should be withheld, got: $filtered1" >&2; exit 1
}
echo "✓ failing-test finding is withheld"

# ── 2. "Add a test for X" finding survives ──────────────────────
input2='- 🟡 Medium Priority: Add a test for the null-handling branch'
filtered2="$(printf '%s' "$input2" | bash "$HELPER" 2>/dev/null)"
[ "$filtered2" = '- 🟡 Medium Priority: Add a test for the null-handling branch' ] || {
  echo "FAIL: add-a-test finding should survive, got: $filtered2" >&2; exit 1
}
echo "✓ add-a-test finding survives"

# ── 3. Finding merely containing "test" survives ────────────────
input3='- 🟡 Medium Priority: Review the test helper for clarity'
filtered3="$(printf '%s' "$input3" | bash "$HELPER" 2>/dev/null)"
[ "$filtered3" = '- 🟡 Medium Priority: Review the test helper for clarity' ] || {
  echo "FAIL: finding with word test but no failure signature should survive, got: $filtered3" >&2; exit 1
}
echo "✓ non-failure test mention survives"

# ── 4. Withheld findings reported on report file ────────────────
report="${tmp_dir}/withheld"
printf '%s' "$input1" | bash "$HELPER" "$report" >/dev/null 2>&1
[ -f "$report" ] || { echo "FAIL: report file not created" >&2; exit 1; }
grep -q 'FooTests.Bar is failing' "$report" || { echo "FAIL: withheld finding missing from report file" >&2; exit 1; }
echo "✓ withheld findings reported on report file"

# ── 5. Empty input is a clean no-op ─────────────────────────────
filtered5="$(printf '' | bash "$HELPER" 2>/dev/null)"
[ -z "$filtered5" ] || { echo "FAIL: empty input should produce empty output, got: $filtered5" >&2; exit 1; }
echo "✓ empty input is a clean no-op"

# ── 6. Section with no failing-test findings passes through ──────
input6='- 🟡 Medium Priority: Simplify the error message
- 🔵 Low Priority: Typo in the doc comment'
filtered6="$(printf '%s' "$input6" | bash "$HELPER" 2>/dev/null)"
[ "$filtered6" = "$input6" ] || {
  echo "FAIL: section with no failing-test findings should pass through byte-identically" >&2
  echo "  expected: $input6" >&2
  echo "  got:      $filtered6" >&2
  exit 1
}
echo "✓ clean section passes through byte-identically"

# ── 7. Continuation lines are withheld with their bullet ────────
input7='- 🟡 Medium Priority: assertion failed on line 42
  This is a continuation of the failing finding
  with more detail about the assertion.'
filtered7="$(printf '%s' "$input7" | bash "$HELPER" 2>/dev/null)"
[ -z "$filtered7" ] || {
  echo "FAIL: continuation lines should be withheld with their bullet, got: $filtered7" >&2; exit 1
}
echo "✓ continuation lines withheld with their bullet"

# ── 8. Case-insensitive matching ─────────────────────────────────
input8='- 🟡 Medium Priority: Test FAILS on Windows'
filtered8="$(printf '%s' "$input8" | bash "$HELPER" 2>/dev/null)"
[ -z "$filtered8" ] || {
  echo "FAIL: case-insensitive match should withhold, got: $filtered8" >&2; exit 1
}
echo "✓ case-insensitive matching works"

# ── 9. "does not pass" signature ─────────────────────────────────
input9='- 🟡 Medium Priority: IntegrationTest does not pass after the refactor'
filtered9="$(printf '%s' "$input9" | bash "$HELPER" 2>/dev/null)"
[ -z "$filtered9" ] || {
  echo "FAIL: does-not-pass should be withheld, got: $filtered9" >&2; exit 1
}
echo "✓ does-not-pass signature matches"

# ── 10. "broken test" signature ──────────────────────────────────
input10='- 🔵 Low Priority: The broken test in module X masks real failures'
filtered10="$(printf '%s' "$input10" | bash "$HELPER" 2>/dev/null)"
[ -z "$filtered10" ] || {
  echo "FAIL: broken test should be withheld, got: $filtered10" >&2; exit 1
}
echo "✓ broken test signature matches"

# ── 11. Generic failure phrasing with NO test word must SURVIVE ──
# Regression: the first implementation matched the bare phrases "does not pass"
# and "is failing", which are ordinary code-review English. Three real findings
# were silently withheld — the exact silent scope loss this filter exists to
# prevent. A tier-2 phrase only counts when the line also names a test.
survives() {
  local label="$1" text="$2" out
  out="$(printf '%s' "$text" | bash "$HELPER" 2>/dev/null)"
  [ "$out" = "$text" ] || {
    echo "FAIL: ${label} must survive (over-match), got: [${out}]" >&2; exit 1
  }
}
survives "does-not-pass without a test word" \
  '- 🟡 Medium Priority: resolve_provider does not pass the scope flag to the resolver'
survives "is-failing without a test word" \
  '- 🟡 Medium Priority: the retry loop is failing to back off between attempts'
survives "does-not-pass on a validation helper" \
  '- 🔵 Low Priority: validate_input does not pass NULL through to the caller'
echo "✓ generic failure phrasing without a test word survives"

# ── 12. Generic phrasing WITH a test word is still withheld ──────
for t in \
  '- 🟡 Medium Priority: FooTests.Bar is failing after this change' \
  '- 🟡 Medium Priority: IntegrationTest does not pass after the refactor' \
  '- 🔵 Low Priority: the auth spec is failing on CI' \
  '- 🔵 Low Priority: BazSpec is red on CI' \
  '- 🟡 Medium Priority: the integration suite is red after the merge'; do
  out="$(printf '%s' "$t" | bash "$HELPER" 2>/dev/null)"
  [ -z "$out" ] || { echo "FAIL: test-anchored generic phrase should be withheld, got: [${out}]" >&2; exit 1; }
done
echo "✓ generic phrasing with a test word is still withheld"

# ── 13. The REAL rendered format: an indented `- ` sub-bullet is a
#        continuation of its parent finding, not a new finding. ────────
# Regression, and the one the unit tests originally missed because their
# continuation lines did not start with "- ". render-findings-summary.sh emits
# `why_it_matters` as a two-space-indented sub-bullet, so treating every "- "
# line as a new finding withheld the parent and leaked its sub-bullet into the
# model's scope as an orphan fragment carrying the failing-test detail.
input13='- **#1** 🟡 [VERIFIED] Medium Priority: FooTests.Bar is failing after this change — `src/A.cs:42` (chunk #0)
  - The assertion no longer matches the new return shape.
- **#2** 🟡 [VERIFIED] Medium Priority: resolve_provider does not pass the scope flag — `lib/rp.sh:10` (chunk #1)'
expected13='- **#2** 🟡 [VERIFIED] Medium Priority: resolve_provider does not pass the scope flag — `lib/rp.sh:10` (chunk #1)'
report13="${tmp_dir}/withheld13"
filtered13="$(printf '%s' "$input13" | bash "$HELPER" "$report13" 2>/dev/null)"
[ "$filtered13" = "$expected13" ] || {
  echo "FAIL: indented sub-bullet must be withheld WITH its parent, not leak." >&2
  echo "  expected: [${expected13}]" >&2
  echo "  got:      [${filtered13}]" >&2
  exit 1
}
grep -q 'The assertion no longer matches' "$report13" || {
  echo "FAIL: the parent's sub-bullet should be in the withheld report" >&2; exit 1
}
count13="$(grep -cE '^[[:space:]]{0,1}- ' "$report13" || true)"
[ "$count13" = "1" ] || {
  echo "FAIL: a parent + sub-bullet is ONE withheld finding, got ${count13}" >&2; exit 1
}
echo "✓ indented sub-bullets stay with their parent finding"

# ── 14. Medium + Low reports concatenate on separate lines ───────
# Regression: the workflow joined the two reports with `withheld+="$(cat …)"`,
# and command substitution strips trailing newlines — so the last medium bullet
# and the first low bullet were glued onto one line and the count said 1.
med="${tmp_dir}/med"; low="${tmp_dir}/low"; all="${tmp_dir}/all"
printf '%s' '- 🟡 Medium Priority: FooTests.Bar is failing here' | bash "$HELPER" "$med" >/dev/null 2>&1
printf '%s' '- 🔵 Low Priority: BazTests broken test here'        | bash "$HELPER" "$low" >/dev/null 2>&1
: > "$all"
for f in "$med" "$low"; do
  [ -s "$f" ] || continue
  cat "$f" >> "$all"
  [ -n "$(tail -c 1 "$all")" ] && printf '\n' >> "$all"
done
joined_count="$(grep -cE '^[[:space:]]*- ' "$all" || true)"
[ "$joined_count" = "2" ] || {
  echo "FAIL: medium+low reports should yield 2 bullets, got ${joined_count}:" >&2
  cat "$all" >&2; exit 1
}
grep -q 'is failing here$' "$all" || { echo "FAIL: medium bullet was glued to the low bullet" >&2; cat "$all" >&2; exit 1; }
echo "✓ medium and low reports stay on separate lines"

echo "✓ filter-failing-test-findings tests passed"