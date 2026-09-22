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

# --- case 6b: UNCLOSED frontmatter keeps the whole file (fail-open) ----------
# The original awk left `infm` set forever when the opening `---` was never
# closed, so every line was swallowed and the rule silently contributed nothing
# — contradicting this script's own docstring ("or the whole content when there
# is none / it is malformed") and inverting LADR-089's asymmetry, where a
# dropped rule is the expensive direction. A stray `---` in the output is the
# cheap one, so malformed frontmatter must fail open.
mkdir -p "$TMP/fmbad"
printf -- '---\napplyTo: backend\nUNCLOSED_RULE_BODY\ntrailing detail\n' > "$TMP/fmbad/rule.md"
printf '%s\n' "$TMP/fmbad/rule.md" > "$TMP/ctx6b.txt"
bash "$BUILDER" "$TMP/ctx6b.txt" "$TMP/out6b" "chunk 6b" > /dev/null 2>&1
grep -q 'UNCLOSED_RULE_BODY' "$TMP/out6b/AGENTS.md" \
  || fail "unclosed frontmatter swallowed the rule body — a silent rule drop"
grep -q 'trailing detail' "$TMP/out6b/AGENTS.md" \
  || fail "unclosed frontmatter swallowed the tail of the rule"
ok "unclosed frontmatter fails open and keeps the whole rule body"

# --- case 7: callers fail OPEN when the runtime AGENTS.md is absent ----------
# The builder degrades gracefully, but a caller that pins OPENCODE_RUN_CWD at a
# directory that does not exist makes `cd` fail inside the transport, so every
# model in the chain returns 1. For a chunk that means a fail-closed
# REQUEST_CHANGES caused purely by an enrichment failure; for the aggregation
# pass it means the fallback summary template. Both callers must therefore guard
# on the generated file existing, never hardcode the path into the env var.
CHUNKS="$SCRIPT_DIR/review-in-chunks.sh"
AGG="$SCRIPT_DIR/aggregate-reviews.sh"

if grep -qE 'OPENCODE_RUN_CWD="ci_temp/chunk_\$\{chunk_num\}"' "$CHUNKS"; then
  fail "review-in-chunks.sh hardcodes OPENCODE_RUN_CWD — a missing runtime AGENTS.md would fail the chunk closed"
fi
grep -q 'if \[ -f "ci_temp/chunk_${chunk_num}/AGENTS.md" \]' "$CHUNKS" \
  || fail "review-in-chunks.sh lost the runtime AGENTS.md existence guard"
[ "$(grep -c 'OPENCODE_RUN_CWD="\$_run_cwd"' "$CHUNKS")" -eq 2 ] \
  || fail "both chunk stages (primary and LADR-081 secondary) must use the guarded cwd"
ok "review-in-chunks.sh fails open when the runtime AGENTS.md is missing"

if grep -qE 'OPENCODE_RUN_CWD="ci_temp/orch"' "$AGG"; then
  fail "aggregate-reviews.sh hardcodes OPENCODE_RUN_CWD — a missing runtime AGENTS.md would force the fallback summary"
fi
grep -q 'if \[ -f ci_temp/orch/AGENTS.md \]' "$AGG" \
  || fail "aggregate-reviews.sh lost the runtime AGENTS.md existence guard"
grep -q 'OPENCODE_RUN_CWD="\$ORCH_RUN_CWD"' "$AGG" \
  || fail "aggregate-reviews.sh must pass the guarded cwd to the transport"
ok "aggregate-reviews.sh fails open when the runtime AGENTS.md is missing"

# --- case 8: the prompt asserts loaded rules only when rules exist -----------
# An empty scoped set yields a runtime AGENTS.md that says so. Telling the model
# "the rules that apply were loaded" in that case is a false premise, which is
# the DR-015 class. The block must sit behind a non-empty context-set test.
grep -q 'if \[ -s ci_temp/chunk_${chunk_num}_context.txt \]' "$CHUNKS" \
  || fail "the PROJECT RULES prompt block is no longer gated on a non-empty context set"
ok "the loaded-rules claim is gated on the chunk actually having context files"

# --- case 9: no hardcoded language/framework facts in the prompt -------------
# The gate is language-agnostic and reviews Python/TS/Go/Rust consumers. A
# hardcoded "this project uses C# 14 with .NET 10" is a false statement about
# most repos under review, and a false premise produces hallucinated findings
# (LADR-015/DR-015). Version facts belong in the consuming repo's own rules,
# which the runtime AGENTS.md now carries.
if grep -vE '^\s*#' "$CHUNKS" | grep -qE 'C# 14|\.NET 10 SDK'; then
  fail "a hardcoded language/framework version claim is back in the chunk prompt"
fi
ok "no hardcoded language/framework version claims in the chunk prompt"

echo ""
echo "All ${pass} build-runtime-agents tests passed."
