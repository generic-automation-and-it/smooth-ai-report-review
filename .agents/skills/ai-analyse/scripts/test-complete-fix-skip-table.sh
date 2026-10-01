#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/scope" <<'EOF'
### Medium
1. 🟡 Finding one
2. 🟡 Finding two
3. 🟡 Finding three
- **R1)** 🟡 Residual risk: one
- **R2)** 🟡 Residual risk: two
- **R3)** 🟡 Residual risk: three
- **T1)** 🟡 Testing gap: one
### Low
- **4.** 🔵 Finding four (literalised after a decision-model withhold)
5. 🔵 Finding five
EOF
cat > "$scratch/model" <<'EOF'
| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|
| **1.** | FIX | Medium | a.sh | one | mechanical |
| 2 | SKIP | Medium | a.sh | two | deferred |
| #4 | SKIP | Low | b.sh | four | invalid |
| **R1)** | SKIP | Medium (residual risk) | — | one | advisory |
| R3) | **SKIP** | Medium (residual risk) | — | three | advisory |
| T1 | FIX | Medium (testing gap) | t.sh | one | focused test |
| 5. | SKIP | Low | c.sh | five | intentional |
EOF
cp "$scratch/model" "$scratch/model.original"
bash "$here/lib/complete-fix-skip-table.sh" "$scratch/scope" "$scratch/model" "$scratch/count" > "$scratch/rows"
test "$(cat "$scratch/count")" = 2
grep -Fq '| 3. | SKIP | Medium |' "$scratch/rows"
grep -Fq '| R2) | SKIP | Medium (residual risk) |' "$scratch/rows"
! grep -Eq '#[0-9]+' "$scratch/rows"
cmp "$scratch/model" "$scratch/model.original"
cat >> "$scratch/model" <<'EOF'
| `3.` | **FIX** | Medium | a.sh | three | mechanical |
| R2 | SKIP | Medium (residual risk) | — | two | advisory |
EOF
bash "$here/lib/complete-fix-skip-table.sh" "$scratch/scope" "$scratch/model" "$scratch/count" > "$scratch/rows"
test "$(cat "$scratch/count")" = 0
test ! -s "$scratch/rows"
sed -i 's/| \*\*FIX\*\* |/| ✅ FIX |/' "$scratch/model"
bash "$here/lib/complete-fix-skip-table.sh" "$scratch/scope" "$scratch/model" "$scratch/count" > "$scratch/rows"
test "$(cat "$scratch/count")" = 0
test ! -s "$scratch/rows"
echo 'complete-fix-skip-table: PASS'
