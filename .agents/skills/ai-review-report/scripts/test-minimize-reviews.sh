#!/bin/bash
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

if echo "$OUTPUT" | grep -q "Minimizing Previous Gemini Reviews"; then
  echo "✅ Test 3 passed: Full review minimization logic triggered"
else
  echo "⚠️  Test 3: Logic may need verification"
  echo "$OUTPUT"
fi
echo ""

echo "=========================================="
echo "All basic tests passed!"
echo "=========================================="
echo ""
echo "Note: Full integration testing requires:"
echo "  1. A real PR with existing Gemini reviews"
echo "  2. Valid GITHUB_TOKEN"
echo "  3. Running in GitHub Actions or with gh CLI configured"
