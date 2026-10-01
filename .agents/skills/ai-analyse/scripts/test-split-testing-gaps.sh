#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/input" <<'EOF'
1. 🟡 [VERIFIED] Medium: changed code — `a.sh:1`
   - finding continuation
- **T1)** 🟡 Testing gap: no test covers the case where an upstream test fails
   - gap continuation
- **R1)** 🟡 Residual risk: local retry may be slow
- **T2)** 🟡 Testing gap: no test covers another branch
EOF
cat > "$scratch/expected" <<'EOF'
1. 🟡 [VERIFIED] Medium: changed code — `a.sh:1`
   - finding continuation
- **R1)** 🟡 Residual risk: local retry may be slow
EOF
bash "$here/lib/split-testing-gaps.sh" "$scratch/report" < "$scratch/input" > "$scratch/actual"
cmp "$scratch/expected" "$scratch/actual"
test "$(cat "$scratch/report.count")" = 2
grep -q 'gap continuation' "$scratch/report"

for value in 1 true yes on TRUE YeS ON; do
  OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX="$value" bash "$here/lib/split-testing-gaps.sh" "$scratch/report" < "$scratch/input" > "$scratch/actual"
  cmp "$scratch/input" "$scratch/actual"
  test "$(cat "$scratch/report.count")" = 0
done
: > "$scratch/empty"
bash "$here/lib/split-testing-gaps.sh" "$scratch/report" < "$scratch/empty" > "$scratch/actual"
cmp "$scratch/empty" "$scratch/actual"
test "$(cat "$scratch/report.count")" = 0

# A T item mentioning a failed test is pre-decided, not classified as a
# failing-test finding when the workflow runs these filters in order.
bash "$here/lib/split-testing-gaps.sh" "$scratch/report" < "$scratch/input" |
  bash "$here/lib/filter-failing-test-findings.sh" "$scratch/failing" > "$scratch/actual"
cmp "$scratch/expected" "$scratch/actual"
test ! -s "$scratch/failing"
echo 'split-testing-gaps: PASS'
