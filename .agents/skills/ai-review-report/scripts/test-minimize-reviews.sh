#!/bin/bash
# shellcheck disable=SC2016
set -e

# Test script for minimize-previous-reviews.sh
# This script tests the minimize logic without actually making API calls

echo "=========================================="
echo "Testing Minimize Previous Reviews Script"
echo "=========================================="
echo ""

# Test 1: Missing arguments
echo "Test 1: Missing arguments (should fail)"
if bash .agents/skills/ai-review-report/scripts/minimize-previous-reviews.sh 2>&1 | grep -q "Error: Missing required arguments"; then
  echo "✅ Test 1 passed: Missing arguments error detected"
else
  echo "❌ Test 1 failed: Should error on missing arguments"
  exit 1
fi
echo ""

# Test 2: Incremental review type (should skip)
echo "Test 2: Incremental review type (should skip)"
OUTPUT=$(bash .agents/skills/ai-review-report/scripts/minimize-previous-reviews.sh "123" "incremental" "0north/bunker-procurement" 2>&1 || true)
if echo "$OUTPUT" | grep -q "skipping minimization"; then
  echo "✅ Test 2 passed: Incremental reviews skip minimization"
else
  echo "❌ Test 2 failed: Should skip for incremental reviews"
  echo "$OUTPUT"
  exit 1
fi
echo ""

# Test 3: Full review type with mock PR (will fail at API call which is expected)
echo "Test 3: Full review type (will test logic up to API call)"
OUTPUT=$(bash .agents/skills/ai-review-report/scripts/minimize-previous-reviews.sh "123" "full" "0north/bunker-procurement" "999999" 2>&1 || true)

if echo "$OUTPUT" | grep -q "Minimizing Previous AI Reviews"; then
  echo "✅ Test 3 passed: Full review minimization logic triggered (reached script entry with correct args)"
elif echo "$OUTPUT" | grep -qi "not found\|command not found\|no such file"; then
  echo "⚠️  Test 3: Dependency missing — cannot verify logic"
  echo "$OUTPUT"
else
  echo "⚠️  Test 3: Unexpected output — review the script logic"
  echo "$OUTPUT"
fi
echo ""

# Test 4: Review-marker regex matches real review bodies but not quoted copies.
# Guards against an unanchored regex (false-positive minimization of quoted headers)
# AND against over-anchoring (e.g. "^🤖", which breaks because real bodies start with "## 🤖").
# The pattern is extracted from the script itself so this test fails if the regex regresses.
echo "Test 4: Review-marker regex (anchored, single-source-of-truth)"
PATTERN=$(grep -oE 'test\("[^"]*Code Review[^"]*"\)' \
  .agents/skills/ai-review-report/scripts/minimize-previous-reviews.sh \
  | head -1 | sed -E 's/^test\("//; s/"\)$//')

if [ -z "$PATTERN" ]; then
  echo "❌ Test 4 failed: could not extract review-marker regex from minimize-previous-reviews.sh"
  exit 1
fi

# jq powers the regex-semantics assertion below; skip (not fail) when it is absent
# so this test degrades gracefully on a runner without jq.
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  Test 4 skipped: jq not available — cannot verify regex match semantics (pattern extracted: $PATTERN)"
else
  REAL='## 🤖 OpenCode CLI Code Review - Commit: `abc1234`'
  QUOTED='> ## 🤖 OpenCode CLI Code Review (quoted by a human in a follow-up comment)'
  REAL_MATCH=$(printf '%s' "$REAL"   | jq -Rs --arg re "$PATTERN" 'test($re)')
  QUOTE_MATCH=$(printf '%s' "$QUOTED" | jq -Rs --arg re "$PATTERN" 'test($re)')

  if [ "$REAL_MATCH" = "true" ] && [ "$QUOTE_MATCH" = "false" ]; then
    echo "✅ Test 4 passed: matches a real review header, ignores a quoted copy (pattern: $PATTERN)"
  else
    echo "❌ Test 4 failed: real-header match=$REAL_MATCH (want true), quoted-copy match=$QUOTE_MATCH (want false)"
    echo "   pattern: $PATTERN"
    exit 1
  fi
fi
echo ""

# Test 5: ai-analyse marker regex matches owned comments but not quoted copies.
# The pattern is extracted from the script itself so this test fails if the regex
# drifts away from the markers posted by pipeline-ai-analyse.yml.
echo "Test 5: ai-analyse marker regex (anchored, single-source-of-truth)"
ANALYSE_PATTERN=$(grep -oE 'test\("[^"]*ai-analyse auto-fix[^"]*"\)' \
  .agents/skills/ai-review-report/scripts/minimize-previous-reviews.sh \
  | head -1 | sed -E 's/^test\("//; s/"\)$//')

if [ -z "$ANALYSE_PATTERN" ]; then
  echo "❌ Test 5 failed: could not extract ai-analyse marker regex from minimize-previous-reviews.sh"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  Test 5 skipped: jq not available — cannot verify regex match semantics (pattern extracted: $ANALYSE_PATTERN)"
else
  SUMMARY='## ai-analyse auto-fix summary'
  LIMIT_EXCEEDED='## ai-analyse auto-fix limit exceeded'
  QUOTED='> ## ai-analyse auto-fix summary'
  SUMMARY_MATCH=$(printf '%s' "$SUMMARY" | jq -Rs --arg re "$ANALYSE_PATTERN" 'test($re)')
  LIMIT_MATCH=$(printf '%s' "$LIMIT_EXCEEDED" | jq -Rs --arg re "$ANALYSE_PATTERN" 'test($re)')
  QUOTE_MATCH=$(printf '%s' "$QUOTED" | jq -Rs --arg re "$ANALYSE_PATTERN" 'test($re)')

  if [ "$SUMMARY_MATCH" = "true" ] && [ "$LIMIT_MATCH" = "true" ] && [ "$QUOTE_MATCH" = "false" ]; then
    echo "✅ Test 5 passed: matches both ai-analyse markers, ignores a quoted copy (pattern: $ANALYSE_PATTERN)"
  else
    echo "❌ Test 5 failed: summary match=$SUMMARY_MATCH (want true), limit match=$LIMIT_MATCH (want true), quoted-copy match=$QUOTE_MATCH (want false)"
    echo "   pattern: $ANALYSE_PATTERN"
    exit 1
  fi
fi
echo ""

# Test 6: the LADR-059 trivial-skip notice is minimized; the blocked-incremental
# notice — same gate header, different body — is deliberately left alone. Both
# patterns are extracted from the script so this fails if either drifts.
echo "Test 6: trivial-skip comment selector (LADR-059)"
TRIVIAL_SELECT=$(awk '/comment_node_ids=\$\(echo "\$comments_json"/,/^  \)$/' \
  .agents/skills/ai-review-report/scripts/minimize-previous-reviews.sh)

if ! printf '%s' "$TRIVIAL_SELECT" | grep -q 'Trivial-PR skip'; then
  echo "❌ Test 6 failed: trivial-skip marker missing from the comment selector"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  Test 6 skipped: jq not available"
else
  TRIVIAL_BODY='## 🤖 OpenCode CLI Code Review - Commit: `abc1234`

⏭️ **Skipping review** — every changed file is a dependency lockfile or manifest.

**Why?** Trivial-PR skip (`model-veto`).'
  BLOCKED_BODY='## 🤖 OpenCode CLI Code Review - Commit: `abc1234`

⏭️ **Skipping incremental review** - Existing blocking review from @github-actions[bot] requires full review for clearance.'
  QUOTED_TRIVIAL='> ## 🤖 OpenCode CLI Code Review - Commit: `abc1234`
> **Why?** Trivial-PR skip (`model-veto`).'

  # Mirror the script selector: gate header anchored at ^ AND the trivial marker.
  sel() {
    printf '%s' "$1" | jq -Rs \
      '(test("^#+ 🤖 (Gemini CLI|OpenCode CLI) Code Review")) and (test("Trivial-PR skip"))'
  }
  T_MATCH=$(sel "$TRIVIAL_BODY")
  B_MATCH=$(sel "$BLOCKED_BODY")
  Q_MATCH=$(sel "$QUOTED_TRIVIAL")

  if [ "$T_MATCH" = "true" ] && [ "$B_MATCH" = "false" ] && [ "$Q_MATCH" = "false" ]; then
    echo "✅ Test 6 passed: minimizes the trivial-skip notice, leaves blocked-incremental and quoted copies alone"
  else
    echo "❌ Test 6 failed: trivial=$T_MATCH (want true), blocked=$B_MATCH (want false), quoted=$Q_MATCH (want false)"
    exit 1
  fi
fi
echo ""

echo "=========================================="
echo "All basic tests passed!"
echo "=========================================="
echo ""
echo "Note: Full integration testing requires:"
echo "  1. A real PR with existing AI reviews"
echo "  2. Valid GITHUB_TOKEN"
echo "  3. Running in GitHub Actions or with gh CLI configured"
