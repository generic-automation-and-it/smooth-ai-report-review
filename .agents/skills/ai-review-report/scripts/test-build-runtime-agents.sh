#!/bin/bash
# Offline regression tests for lib/build-runtime-agents.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/lib/build-runtime-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "❌ $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "✅ $*"; }

# --- gather: one context file per line in a list file -------------------------
LIST="$TMP/ctx.txt"
mkdir -p "$TMP/rules"
printf '%s\n' "$TMP/rules/clean.md" > "$LIST"
cat > "$TMP/rules/clean.md" <<'EOF'
# CLEAN_CODE_RULE
Meaningful naming only.
EOF

# --- case 1: concatenates content of listed context files --------------------
OUT1="$(bash "$BUILDER" "$LIST" "$TMP/out1" "chunk 1")"
[ -n "$OUT1" ] || fail "builder did not print an output path"
[ -f "$TMP/out1/AGENTS.md" ] || fail "AGENTS.md not created in target dir"
grep -q 'CLEAN_CODE_RULE' "$TMP/out1/AGENTS.md" || fail "rule content missing from runtime AGENTS.md"
grep -q 'Meaningful naming only.' "$TMP/out1/AGENTS.md" || fail "rule detail missing"
grep -q 'chunk 1' "$TMP/out1/AGENTS.md" || fail "source label not in header"
ok "listed context file content is concatenated into the runtime AGENTS.md"

# --- case 2: exact AGENTS.md basename is excluded -----------------------------
printf '%s\n' "$TMP/rules/clean.md" "AGENTS.md" "some/deep/AGENTS.md" > "$TMP/ctx2.txt"
bash "$BUILDER" "$TMP/ctx2.txt" "$TMP/out2" "chunk 2" > /dev/null 2>&1
if grep -q '^Source: `AGENTS.md`' "$TMP/out2/AGENTS.md"; then
  fail "exact AGENTS.md basename was duplicated into the runtime AGENTS.md"
fi
grep -q 'CLEAN_CODE_RULE' "$TMP/out2/AGENTS.md" || fail "rule content lost when AGENTS.md paths present"
ok "exact AGENTS.md basenames are excluded (native v2 scope owns them)"

# --- case 3: empty/missing list yields a minimal valid AGENTS.md --------------
mkdir -p "$TMP/empty"
: > "$TMP/empty_list.txt"
OUT3="$(bash "$BUILDER" "$TMP/empty_list.txt" "$TMP/out3" "chunk 3")"
[ -f "$TMP/out3/AGENTS.md" ] || fail "no AGENTS.md produced for empty context list"
grep -q '# Runtime review instructions' "$TMP/out3/AGENTS.md" || fail "minimal AGENTS.md missing header"
ok "empty context list still yields a valid minimal AGENTS.md"

# --- case 4: missing context file warns and is skipped ------------------------
printf '%s\n' "$TMP/rules/clean.md" "$TMP/gone/not-there.md" > "$TMP/ctx4.txt"
bash "$BUILDER" "$TMP/ctx4.txt" "$TMP/out4" "chunk 4" > /dev/null 2>"$TMP/err4"
grep -q 'CLEAN_CODE_RULE' "$TMP/out4/AGENTS.md" || fail "present rule not included"
grep -q 'not-there.md' "$TMP/err4" || fail "missing context file was not warned"
ok "missing context file warns to stderr without aborting"

# --- case 5: target dir is created if absent ----------------------------------
rm -rf "$TMP/created/sub"
helper_out="$(bash "$BUILDER" "$LIST" "$TMP/created/sub" "chunk 5")"
[ -f "$TMP/created/sub/AGENTS.md" ] || fail "target dir not created"
ok "target directory is created when absent"

# --- case 6: leading YAML frontmatter is stripped from rule content -----------
mkdir -p "$TMP/fm"
printf '%s\n' "$TMP/fm/rule.md" > "$TMP/ctx6.txt"
cat > "$TMP/fm/rule.md" <<'EOF'
---
applyTo: backend
alwaysApply: false
---
ACTUAL_RULE_CONTENT
More rule detail.
EOF
bash "$BUILDER" "$TMP/ctx6.txt" "$TMP/out6" "chunk 6" > /dev/null 2>&1
grep -q 'ACTUAL_RULE_CONTENT' "$TMP/out6/AGENTS.md" || fail "rule body lost after frontmatter strip"
grep -q 'More rule detail.' "$TMP/out6/AGENTS.md" || fail "rule body detail lost"
if grep -q 'applyTo\|alwaysApply' "$TMP/out6/AGENTS.md"; then
  fail "scope-filter frontmatter leaked into the runtime AGENTS.md"
fi
ok "scope-filter frontmatter (applyTo/alwaysApply) is stripped from rule content"

echo ""
echo "All ${pass} build-runtime-agents tests passed."
