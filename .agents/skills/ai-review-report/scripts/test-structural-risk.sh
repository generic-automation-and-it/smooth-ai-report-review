#!/usr/bin/env bash
# test-structural-risk.sh — the presentation-only Structural Risk block
# (HLD-003 LADR-06, HLD-001 Goal 4). V4 of the graph-data adoption.
#
#   Part 1: lib/render-structural-risk.sh — gating, content safety.
#   Part 2: lib/insert-structural-risk.sh + lib/strip-structural-risk.sh —
#           placement, every fail-open fallback, byte-exact removal.
#   Part 3: the REAL aggregate-reviews.sh end to end with a stub transport,
#           flag on vs off: identical review_action, identical parser output,
#           and the flag-on body minus the block equals the flag-off body.
#   Part 4: run-review.sh's size ladder drops the block before compaction.
#
# Requires Bash >= 4 and GNU timeout (aggregate's summary call is bounded).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib"
RENDER="${LIB}/render-structural-risk.sh"
INSERT="${LIB}/insert-structural-risk.sh"
STRIP="${LIB}/strip-structural-risk.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

BEGIN_MARK='<!-- ai-review-report:structural-risk:begin -->'

# A graph >= 2.4.0 payload with every field the block reads.
GRAPH="${TMP_DIR}/graph.json"
cat > "$GRAPH" << 'JSON'
{
  "risk_score": 0.612,
  "changed_functions": [
    {"file_path": "src/a.py", "line_start": 10, "name": "alpha", "risk_score": 0.81},
    {"file_path": "src/a.py", "line_start": 30, "name": "beta", "risk_score": 0.2},
    {"file_path": "src/b.py", "line_start": 5, "name": "gamma", "risk_score": 0.4}
  ],
  "affected_flows": [{"name": "f"}, {"name": "g"}],
  "test_gaps": [
    {"file": "src/a.py", "line_start": 10, "name": "alpha", "coverage": "none"},
    {"file": "src/b.py", "line_start": 5, "name": "gamma", "coverage": "indirect", "covered_by": ["tests/t.py::t"]}
  ],
  "removed_symbols": [
    {"name": "gone", "qualified_name": "src/a.py::gone", "file": "src/a.py", "old_line_start": 40, "used_by_total": 2},
    {"name": "quiet", "qualified_name": "src/a.py::quiet", "file": "src/a.py", "old_line_start": 50, "used_by_total": 0},
    {"name": "bad#7", "qualified_name": "bad#7", "file": "src/a.py", "old_line_start": 60, "used_by_total": 1}
  ]
}
JSON
STATE="${TMP_DIR}/state.json"
printf '{"graph_version":"2.4.0","churn_status":"ok","removed_symbols_total":3}\n' > "$STATE"

render() { bash "$RENDER" "$@"; }

echo "Part 1: renderer gating and content"
check "flag unset → no block" "" "$(GRAPH_ANALYSIS_AVAILABLE=true render "$GRAPH" "$STATE")"
check "flag off → no block" "" "$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=0 GRAPH_ANALYSIS_AVAILABLE=true render "$GRAPH" "$STATE")"
check "graph not available → no block" "" "$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1 GRAPH_ANALYSIS_AVAILABLE=failed render "$GRAPH" "$STATE")"
: > "${TMP_DIR}/empty.json"
check "empty graph data → no block" "" "$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1 GRAPH_ANALYSIS_AVAILABLE=true render "${TMP_DIR}/empty.json")"
printf 'not json' > "${TMP_DIR}/bad.json"
check "invalid graph data → no block" "" "$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1 GRAPH_ANALYSIS_AVAILABLE=true render "${TMP_DIR}/bad.json")"
check "no graph path → no block" "" "$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1 GRAPH_ANALYSIS_AVAILABLE=true render)"

BLOCK="$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1 GRAPH_ANALYSIS_AVAILABLE=true render "$GRAPH" "$STATE")"
printf '%s\n' "$BLOCK" > "${TMP_DIR}/block.md"
check "block opens with its own ## heading" "## 🧭 Structural Risk (graph)" "$(printf '%s\n' "$BLOCK" | head -n1)"
check "the begin marker sits directly under the heading" "$BEGIN_MARK" "$(printf '%s\n' "$BLOCK" | sed -n 2p)"
check "overall risk and churn state" "1" "$(printf '%s\n' "$BLOCK" | grep -cx -- '- \*\*Overall risk:\*\* 0.61 · change frequency included')"
check "changed functions, files and risk ≥ 0.7 count" "1" "$(printf '%s\n' "$BLOCK" | grep -cx -- '- \*\*Changed functions:\*\* 3 across 2 file(s); 1 at risk 0.7 or above')"
check "affected flows" "1" "$(printf '%s\n' "$BLOCK" | grep -cx -- '- \*\*Affected flows:\*\* 2')"
check "direct vs indirect gaps" "1" "$(printf '%s\n' "$BLOCK" | grep -cx -- '- \*\*Test gaps (graph-inferred):\*\* 1 with no test edge found, 1 reached only through a caller')"
check "removed-but-used lists only safe, still-used symbols" "1" "$(printf '%s\n' "$BLOCK" | grep -cx -- '- \*\*Removed but still referenced (graph):\*\* `src/a.py:40` gone (2 users)')"
check "no '#'+digits anywhere in the block" "0" "$(printf '%s\n' "$BLOCK" | grep -cE '#[0-9]')"
check "no severity emoji or label in the block" "0" "$(printf '%s\n' "$BLOCK" | grep -cE '🔴|🟠|🟡|🔵|Critical|High Priority|Medium Priority|Low Priority')"
check "no numbered (finding-shaped) line in the block" "0" "$(printf '%s\n' "$BLOCK" | grep -cE '^[0-9]+\. ')"
check "no R/T/P identifier in the block" "0" "$(printf '%s\n' "$BLOCK" | grep -cE '\*\*[RTP][0-9]+\)\*\*')"
printf '{"graph_version":"2.4.0","churn_status":"unavailable"}\n' > "${TMP_DIR}/state_u.json"
check "churn unavailable is stated" "1" "$(OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1 GRAPH_ANALYSIS_AVAILABLE=true render "$GRAPH" "${TMP_DIR}/state_u.json" | grep -c 'change frequency unavailable')"

echo ""
echo "Part 2: placement, fallbacks and strip"
BODY_STD='## 🤖 Smooth AI Review — Commit: `abc1234`

**Review Type:** FULL

---

## 📋 Overall Summary
Prose.

## 🔍 Issues Summary

### 🟡 Medium Priority Issues
1. 🟡 [VERIFIED] Medium Priority: thing — `src/a.py:3`
   - why

### 📊 Coverage

- **Duplicates merged across chunks:** 0

## 📝 Suggested Fixes
Fix it.

## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** comment'

place() { printf '%s\n' "$1" > "${TMP_DIR}/body.md"; bash "$INSERT" "${TMP_DIR}/body.md" "${TMP_DIR}/block.md"; echo "rc=$?" > "${TMP_DIR}/rc"; }

place "$BODY_STD"
check "standard body: inserter exits 0" "rc=0" "$(cat "${TMP_DIR}/rc")"
check "standard body: block sits directly before Suggested Fixes" "## 📝 Suggested Fixes" \
  "$(awk -v m='<!-- ai-review-report:structural-risk:end -->' 'f && NF { print; exit } $0 == m { f = 1 }' "${TMP_DIR}/body.md")"
check "standard body: block is after the Issues Summary" "1" \
  "$(awk '/^## 🔍 Issues Summary/ { s = NR } /^## 🧭 Structural Risk/ { print (s && NR > s) ? 1 : 0 }' "${TMP_DIR}/body.md")"
check "standard body: strip restores the original bytes" "$(printf '%s\n' "$BODY_STD")" "$(bash "$STRIP" < "${TMP_DIR}/body.md")"

BODY_STUB='## 🤖 Smooth AI Review — Commit: `abc1234`

> ⚠️ **Review coverage incomplete:** banner

---

## ⚠️ Summary generation failed
Read the chunk sections.'
place "$BODY_STUB"
check "no anchors: inserter exits 0" "rc=0" "$(cat "${TMP_DIR}/rc")"
check "no anchors: block lands after the banner region, before the first rule" "---" \
  "$(awk -v m='<!-- ai-review-report:structural-risk:end -->' 'f && NF { print; exit } $0 == m { f = 1 }' "${TMP_DIR}/body.md")"
check "no anchors: prose unchanged after strip" "$(printf '%s\n' "$BODY_STUB")" "$(bash "$STRIP" < "${TMP_DIR}/body.md")"

BODY_ISSUES_ONLY='## 🔍 Issues Summary
1. 🟡 [VERIFIED] Medium Priority: thing — `src/a.py:3`'
place "$BODY_ISSUES_ONLY"
check "Issues Summary without Recommendation and no rule: appended at the end" \
  "<!-- ai-review-report:structural-risk:end -->" "$(grep -v '^$' "${TMP_DIR}/body.md" | tail -n1)"
check "appended: prose unchanged after strip (one trailing blank)" "$(printf '%s\n\n' "$BODY_ISSUES_ONLY")" "$(bash "$STRIP" < "${TMP_DIR}/body.md"; echo)"

BODY_FENCED='## 🔍 Issues Summary

### 🟡 Medium Priority Issues
1. 🟡 [VERIFIED] Medium Priority: thing — `src/a.py:3`
   - the report must contain:

```markdown
## 📋 Overall Summary
---
```

## 📝 Suggested Fixes
Fix it.

## 🎯 Recommendation
**MACHINE_READABLE_ACTION:** comment'
place "$BODY_FENCED"
check "fenced example heading: block still lands before Suggested Fixes, outside the fence" "## 📝 Suggested Fixes" \
  "$(awk -v m='<!-- ai-review-report:structural-risk:end -->' 'f && NF { print; exit } $0 == m { f = 1 }' "${TMP_DIR}/body.md")"
check "fenced example heading: the quoted fence is unchanged" "$(printf '%s\n' "$BODY_FENCED")" "$(bash "$STRIP" < "${TMP_DIR}/body.md")"
BODY_FENCED_ONLY='## 🤖 Smooth AI Review

```
## 🔍 Issues Summary
## 🎯 Recommendation
```

---

prose'
place "$BODY_FENCED_ONLY"
check "anchors only inside a fence are not anchors: fallback before the first real rule" "---" \
  "$(awk -v m='<!-- ai-review-report:structural-risk:end -->' 'f && NF { print; exit } $0 == m { f = 1 }' "${TMP_DIR}/body.md")"

printf 'x\n' > "${TMP_DIR}/plain.md"
bash "$INSERT" "${TMP_DIR}/plain.md" "${TMP_DIR}/missing-block.md"; rc=$?
check "missing block file: exit 0, body untouched" "0:x" "${rc}:$(cat "${TMP_DIR}/plain.md")"
bash "$INSERT" "${TMP_DIR}/no-such-body.md" "${TMP_DIR}/block.md"; rc=$?
check "missing body file: exit 0" "0" "$rc"

QUOTED="$(printf 'prose\n## 🧭 Structural Risk (graph)\n%s\nmore prose\n' "$BEGIN_MARK")"
check "an unterminated quoted marker strips nothing" "$QUOTED" "$(printf '%s\n' "$QUOTED" | bash "$STRIP")"
QUOTED2="$(printf 'prose\n%s\nx\n<!-- ai-review-report:structural-risk:end -->\n' "$BEGIN_MARK")"
check "a marker pair without the heading above strips nothing" "$QUOTED2" "$(printf '%s\n' "$QUOTED2" | bash "$STRIP")"
check "strip is the identity on a body without a block" "$(printf '%s\n' "$BODY_STD")" "$(printf '%s\n' "$BODY_STD" | bash "$STRIP")"

echo ""
echo "Part 3: aggregate-reviews.sh end to end, flag on vs off"
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$REAL_TIMEOUT" ] || ! "$REAL_TIMEOUT" --version 2>/dev/null | grep -q 'GNU coreutils'; then
  bad "GNU timeout required for the end-to-end part (macOS: brew install coreutils)"
else
  SANDBOX="${TMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.agents/skills/ai-review-report" "${TMP_DIR}/bin"
  cp -R "${SCRIPT_DIR}" "${SANDBOX}/.agents/skills/ai-review-report/scripts"
  git -c init.defaultBranch=main init -q "$SANDBOX"
  ln -s "$REAL_TIMEOUT" "${TMP_DIR}/bin/timeout"
  cat > "${TMP_DIR}/bin/opencode" << 'STUB'
#!/bin/bash
cat > /dev/null
cat << 'EOF'
## 📋 Overall Summary
A stubbed summary long enough to pass the transport's minimum output floor, which
rejects very short answers as silent provider failures before they get here.

## 🔍 Issues Summary

### 🟡 Medium Priority Issues
1. 🟡 [VERIFIED] Medium Priority: stubbed issue — `src/a.py:3`
   - why it matters

### 🔵 Low Priority
- None found.

## 📝 Suggested Fixes
1) Fix the stubbed issue.

## 🎯 Recommendation
**Decision:** COMMENT
**Rationale:** stubbed

**MACHINE_READABLE_ACTION:** comment
EOF
STUB
  chmod +x "${TMP_DIR}/bin/opencode"
  cp "$GRAPH" "${TMP_DIR}/g.json"
  cp "$STATE" "${TMP_DIR}/s.json"

  run_agg() {
    local name="$1"; shift
    rm -rf "${SANDBOX}/ci_temp"
    mkdir -p "${SANDBOX}/ci_temp/reviews"
    printf '### 📄 File: `src/a.py`\n\n**Issues Found:**\n- None found.\n' > "${SANDBOX}/ci_temp/reviews/chunk_0.md"
    : > "${TMP_DIR}/${name}.gh"
    (
      cd "$SANDBOX" || exit 1
      env PATH="${TMP_DIR}/bin:${PATH}" \
        OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai \
        OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=orch \
        OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS=0 \
        GITHUB_OUTPUT="${TMP_DIR}/${name}.gh" \
        GRAPH_ANALYSIS_AVAILABLE=true \
        "$@" \
        bash .agents/skills/ai-review-report/scripts/aggregate-reviews.sh \
          1 review full aaaaaaa1111 1 bbbbbbb2222 "test expertise" none "" "" \
          "${TMP_DIR}/g.json" "${TMP_DIR}/s.json"
    ) > "${TMP_DIR}/${name}.log" 2>&1
    cp "${SANDBOX}/ci_temp/final_review.md" "${TMP_DIR}/${name}.md" 2>/dev/null || : > "${TMP_DIR}/${name}.md"
    if [ -f "${SANDBOX}/ci_temp/structural_risk_emitted" ]; then echo yes; else echo no; fi > "${TMP_DIR}/${name}.flag"
  }

  run_agg off OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=0
  run_agg on OPENCODE_REVIEW_REPORT_GRAPH_STRUCTURAL_RISK=1

  check "flag off: no block in the body" "0" "$(grep -cxF -- "$BEGIN_MARK" "${TMP_DIR}/off.md")"
  check "flag off: no emitted flag" "no" "$(cat "${TMP_DIR}/off.flag")"
  check "flag on: exactly one block in the body" "1" "$(grep -cxF -- "$BEGIN_MARK" "${TMP_DIR}/on.md")"
  check "flag on: emitted flag written for the size ladder" "yes" "$(cat "${TMP_DIR}/on.flag")"
  check "review_action identical with the block on" \
    "$(grep '^review_action=' "${TMP_DIR}/off.gh" | tail -1)" "$(grep '^review_action=' "${TMP_DIR}/on.gh" | tail -1)"
  check "flag-on body minus the block equals the flag-off body" \
    "$(cat "${TMP_DIR}/off.md")" "$(bash "$STRIP" < "${TMP_DIR}/on.md")"
  check "findings parser output identical" \
    "$(bash "${LIB}/review-findings-to-json.sh" "${TMP_DIR}/off.md")" "$(bash "${LIB}/review-findings-to-json.sh" "${TMP_DIR}/on.md")"
  check "ai-analyse scope extraction identical" \
    "$(bash "${LIB}/extract-ai-analyse-scope.sh" "${TMP_DIR}/off.md")" "$(bash "${LIB}/extract-ai-analyse-scope.sh" "${TMP_DIR}/on.md")"
  check "findings parser saw the stubbed finding (the comparison is not vacuous)" "1" \
    "$(bash "${LIB}/review-findings-to-json.sh" "${TMP_DIR}/on.md" | jq '.findings | length')"
fi

echo ""
echo "Part 4: run-review.sh drops the block before compaction"
RR="${SCRIPT_DIR}/run-review.sh"
strip_line="$(grep -n 'lib/strip-structural-risk.sh' "$RR" | head -n1 | cut -d: -f1)"
compact_line="$(grep -n 'building compact version' "$RR" | head -n1 | cut -d: -f1)"
check "the strip rung precedes compaction and truncation" "1" \
  "$([ -n "$strip_line" ] && [ -n "$compact_line" ] && [ "$strip_line" -lt "$compact_line" ] && echo 1 || echo 0)"
check "the strip rung is gated on the out-of-band emitted flag" "1" \
  "$(grep -c '\[ -f "\$WORK_DIR/structural_risk_emitted" \]' "$RR")"
check "aggregate receives the graph data positionally" "1" \
  "$(grep -A2 '"\${OPENCODE_VERSION_FOOTER:-}" \\$' "$RR" | grep -c 'graph_detect_changes.json')"

# Execute the real strip rung, extracted from run-review.sh, on an oversize body.
rung="$(awk '/^# HLD-001 Goal 4: the presentation-only Structural Risk block/ { f = 1 } f { print } f && /^fi$/ { exit }' "$RR")"
check "the strip rung extracts from run-review.sh" "1" "$(printf '%s\n' "$rung" | grep -c 'lib/strip-structural-risk.sh')"
LADDER="${TMP_DIR}/ladder"
mkdir -p "$LADDER"
place "$BODY_STD"
cp "${TMP_DIR}/body.md" "$LADDER/review_comment.md"
: > "$LADDER/structural_risk_emitted"
out="$( WORK_DIR="$LADDER" SCRIPT_DIR="$SCRIPT_DIR" MAX_BODY_SIZE=10 \
        BODY_SIZE="$(wc -c < "$LADDER/review_comment.md" | tr -d ' ')"; eval "$rung"; echo "BODY_SIZE=$BODY_SIZE" )"
check "oversize body: the block is dropped whole" "0" "$(grep -c 'structural-risk\|Structural Risk' "$LADDER/review_comment.md")"
check "oversize body: the Issues Summary is intact (byte-identical to the body without the block)" \
  "$(printf '%s\n' "$BODY_STD")" "$(cat "$LADDER/review_comment.md")"
check "oversize body: BODY_SIZE is recomputed for the next rung" \
  "BODY_SIZE=$(wc -c < "$LADDER/review_comment.md" | tr -d ' ')" "$(printf '%s\n' "$out" | tail -n1)"
cp "${TMP_DIR}/body.md" "$LADDER/review_comment.md"
rm -f "$LADDER/structural_risk_emitted"
( WORK_DIR="$LADDER" SCRIPT_DIR="$SCRIPT_DIR" MAX_BODY_SIZE=10 BODY_SIZE=99999; eval "$rung" ) > /dev/null
check "no emitted flag: the rung leaves the body alone" "1" "$(grep -cxF -- "$BEGIN_MARK" "$LADDER/review_comment.md")"

echo ""
echo "=========================================="
echo "Results: ${pass} passed, ${fail} failed"
echo "=========================================="
[ "$fail" -eq 0 ]
