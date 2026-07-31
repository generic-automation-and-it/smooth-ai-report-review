#!/bin/bash
# test-code-graph.sh — tests for the code graph analysis scripts (LADR-049).
#
# Tests:
#   1. build-code-graph.sh version resolution (latest vs pinned)
#   2. build-code-graph.sh graceful failure when pip install fails
#   3. detect-changes-graph.sh graceful degradation when graph DB missing
#   4. detect-changes-graph.sh graceful degradation when code-review-graph not on PATH
#   5. run-review.sh env var defaults (GRAPH_ANALYSIS defaults to disabled)
#
# Run: bash test-code-graph.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

tmp_dir="$(mktemp -d)"
# Clean up both the temp dir and any CWD side-effects from tests
cleanup() {
  rm -rf "$tmp_dir"
  rm -rf "$PWD/.code-review-graph" "$PWD/ci_temp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# --- Test 1: build-code-graph.sh version resolution --------------------------
echo ""
echo "Test 1: Version resolution (REQUESTED_VERSION parsing)"

# Mock pip and code-review-graph to test version logic without real install
mock_bin="${tmp_dir}/mock_bin"
mkdir -p "$mock_bin"

# Create a mock code-review-graph that returns a version
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "2.3.6"
  exit 0
fi
if [ "$1" = "build" ]; then
  # Create a fake graph DB
  mkdir -p .code-review-graph
  echo "fake-db" > .code-review-graph/graph.db
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"

# Create a mock pip that succeeds
cat > "${mock_bin}/pip" <<'MOCK_EOF'
#!/bin/bash
exit 0
MOCK_EOF
chmod +x "${mock_bin}/pip"

# Test: when code-review-graph is on PATH with matching version, skip install
PATH="${mock_bin}:${PATH}" \
  OPENCODE_REVIEW_REPORT_GRAPH_VERSION="2.3.6" \
  bash "${LIB_DIR}/build-code-graph.sh" > "${tmp_dir}/test1.out" 2>&1 || {
    cat "${tmp_dir}/test1.out"
    fail "Test 1: should succeed when version matches"
  }
grep -q "code-review-graph found on PATH" "${tmp_dir}/test1.out" || {
  cat "${tmp_dir}/test1.out"
  fail "Test 1: should detect existing install"
}
pass "Test 1: version match detected, install skipped"

# Clean up fake graph
rm -rf .code-review-graph

# --- Test 2: build-code-graph.sh version mismatch triggers install -----------
echo ""
echo "Test 2: Version mismatch triggers install and fails on mismatch"

# Create mocks for pipx and python3 so the script doesn't try to install real packages
cat > "${mock_bin}/pipx" <<'MOCK_EOF'
#!/bin/bash
# Mock pipx: succeed on install but don't actually install anything
exit 0
MOCK_EOF
chmod +x "${mock_bin}/pipx"

cat > "${mock_bin}/python3" <<'MOCK_EOF'
#!/bin/bash
# Mock python3: only used for pip install fallback, which we don't need
exit 0
MOCK_EOF
chmod +x "${mock_bin}/python3"

# Request 2.4.0 but mock returns 2.3.6 — should fail version check
PATH="${mock_bin}:${PATH}" \
  OPENCODE_REVIEW_REPORT_GRAPH_VERSION="2.4.0" \
  bash "${LIB_DIR}/build-code-graph.sh" > "${tmp_dir}/test2.out" 2>&1 && {
    cat "${tmp_dir}/test2.out"
    fail "Test 2: should fail when installed version mismatches requested"
  }
grep -q "version mismatch" "${tmp_dir}/test2.out" || {
  cat "${tmp_dir}/test2.out"
  fail "Test 2: should report version mismatch"
}
pass "Test 2: version mismatch detected and reported correctly"

rm -rf .code-review-graph

# --- Test 3: detect-changes-graph.sh graceful degradation (no graph DB) ------
echo ""
echo "Test 3: Graceful degradation when graph DB missing"

# Ensure no graph DB exists
rm -rf .code-review-graph

# Create a mock code-review-graph
PATH="${mock_bin}:${PATH}" \
  MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test3.out" 2>&1 || {
    cat "${tmp_dir}/test3.out"
    fail "Test 3: should exit 0 even when graph DB missing"
  }
grep -q "Code graph not built" "${tmp_dir}/test3.out" || {
  cat "${tmp_dir}/test3.out"
  fail "Test 3: should detect missing graph DB"
}
# Verify empty output files were created
[ -f "ci_temp/graph_detect_changes.json" ] || fail "Test 3: should create empty JSON file"
[ -f "ci_temp/graph_risk_summary.md" ] || fail "Test 3: should create empty summary file"
[ -f "ci_temp/graph_file_risks.txt" ] || fail "Test 3: should create empty risks file"
pass "Test 3: graceful degradation when graph DB missing"

rm -rf ci_temp

# --- Test 4: detect-changes-graph.sh graceful degradation (no CLI) -----------
echo ""
echo "Test 4: Graceful degradation when code-review-graph not on PATH"

# Create a graph DB but remove the CLI from PATH
mkdir -p .code-review-graph
echo "fake-db" > .code-review-graph/graph.db

# Use a PATH that doesn't include the mock
env -i PATH="/usr/bin:/bin" HOME="$HOME" \
  MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test4.out" 2>&1 || {
    cat "${tmp_dir}/test4.out"
    fail "Test 4: should exit 0 even when CLI not found"
  }
grep -q "code-review-graph not found" "${tmp_dir}/test4.out" || {
  cat "${tmp_dir}/test4.out"
  fail "Test 4: should detect missing CLI"
}
pass "Test 4: graceful degradation when CLI not on PATH"

rm -rf .code-review-graph ci_temp

# --- Test 5: run-review.sh env var defaults ----------------------------------
echo ""
echo "Test 5: run-review.sh env var defaults"

# Extract just the env var defaults from run-review.sh (lines around the GRAPH vars)
grep -A2 'OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS=' "${SCRIPT_DIR}/run-review.sh" | head -3 > "${tmp_dir}/test5.env"
grep -q 'OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS:-1' "${tmp_dir}/test5.env" || {
  cat "${tmp_dir}/test5.env"
  fail "Test 5: GRAPH_ANALYSIS should default to 1"
}
pass "Test 5: GRAPH_ANALYSIS defaults to 1 (enabled)"

# --- Test 6: detect-changes-graph.sh with valid graph DB + mock CLI ----------
echo ""
echo "Test 6: Full flow with mock graph DB and CLI"

# Create a graph DB
mkdir -p .code-review-graph
echo "fake-db" > .code-review-graph/graph.db

# Create a mock code-review-graph that outputs valid JSON
# Note: the mock must be named "code-review-graph" to be found on PATH
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "2.3.6"
  exit 0
fi
if [ "$1" = "detect-changes" ]; then
  # Check if --format json is requested
  if echo "$@" | grep -q "\-\-format json"; then
    cat <<'JSON_EOF'
{
  "changed_functions": [
    {
      "file": "src/controllers/order_controller.cs",
      "line": 42,
      "name": "ProcessOrder",
      "risk_score": 0.85,
      "callers": ["api_handler", "background_worker"],
      "tests": []
    },
    {
      "file": "src/services/pricing_service.cs",
      "line": 15,
      "name": "ValidatePrice",
      "risk_score": 0.45,
      "callers": ["order_controller"],
      "tests": ["pricing_tests.cs"]
    }
  ],
  "affected_flows": [
    {
      "name": "OrderSubmissionFlow",
      "criticality": "high",
      "node_count": 8
    }
  ],
  "test_gaps": [
    {
      "file": "src/controllers/order_controller.cs",
      "function": "ProcessOrder",
      "risk_score": 0.85
    }
  ],
  "context_savings": {
    "savings_pct": 82
  }
}
JSON_EOF
  else
    echo "Changed functions: 2"
    echo "High-risk: 1"
  fi
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"

mkdir -p ci_temp

PATH="${mock_bin}:${PATH}" \
  MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test6.out" 2>&1 || {
    cat "${tmp_dir}/test6.out"
    fail "Test 6: should succeed with valid mock"
  }

# Verify JSON output
[ -s "ci_temp/graph_detect_changes.json" ] || fail "Test 6: JSON should be non-empty"
jq empty "ci_temp/graph_detect_changes.json" 2>/dev/null || {
  echo "JSON content:"
  cat "ci_temp/graph_detect_changes.json"
  fail "Test 6: JSON should be valid"
}

# Verify summary was generated
[ -s "ci_temp/graph_risk_summary.md" ] || fail "Test 6: summary should be non-empty"
grep -q "High-Risk Changed Functions" "ci_temp/graph_risk_summary.md" || fail "Test 6: summary should mention high-risk functions"
grep -q "ProcessOrder" "ci_temp/graph_risk_summary.md" || fail "Test 6: summary should mention ProcessOrder"

# Verify file risks
[ -s "ci_temp/graph_file_risks.txt" ] || fail "Test 6: file risks should be non-empty"
grep -q "order_controller.cs" "ci_temp/graph_file_risks.txt" || fail "Test 6: should include order_controller.cs"

# Verify counts in output
grep -q "High-risk functions.*1" "${tmp_dir}/test6.out" || fail "Test 6: should report 1 high-risk function"
grep -q "Test coverage gaps.*1" "${tmp_dir}/test6.out" || fail "Test 6: should report 1 test gap"

pass "Test 6: full flow with mock produces correct output"

# --- Cleanup from Test 6 ------------------------------------------------------
rm -rf .code-review-graph ci_temp

# --- Test 7: Incremental update branch ----------------------------------------
echo ""
echo "Test 7: Incremental update when graph DB already exists"

# Create a mock code-review-graph that distinguishes full vs incremental builds
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "2.3.6"
  exit 0
fi
if [ "$1" = "build" ]; then
  if echo "$@" | grep -q "\-\-incremental"; then
    echo "incremental-build"
    # Extract --base value if present
    base_val=""
    for arg in "$@"; do
      if [ "$prev_was_base" = "true" ]; then
        base_val="$arg"
        break
      fi
      if [ "$arg" = "--base" ]; then
        prev_was_base="true"
      fi
    done
    if [ -n "$base_val" ]; then
      echo "  base: $base_val"
    fi
  else
    echo "full-build"
  fi
  mkdir -p .code-review-graph
  echo "fake-db" > .code-review-graph/graph.db
  exit 0
fi
if [ "$1" = "stats" ]; then
  echo "Nodes: 42, Edges: 87"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"

# Pre-create graph DB to trigger incremental path
mkdir -p .code-review-graph
echo "old-db" > .code-review-graph/graph.db

PATH="${mock_bin}:${PATH}" \
  OPENCODE_REVIEW_REPORT_GRAPH_BASE_REF="origin/main" \
  bash "${LIB_DIR}/build-code-graph.sh" > "${tmp_dir}/test7.out" 2>&1 || {
    cat "${tmp_dir}/test7.out"
    fail "Test 7: incremental build should succeed"
  }
grep -q "incremental-build" "${tmp_dir}/test7.out" || {
  cat "${tmp_dir}/test7.out"
  fail "Test 7: should use incremental build when graph DB exists"
}
grep -q "origin/main" "${tmp_dir}/test7.out" || {
  cat "${tmp_dir}/test7.out"
  fail "Test 7: should pass base ref to incremental build"
}
pass "Test 7: incremental update branch works correctly"

# --- Test 8: Incremental build falls back to full on failure ------------------
echo ""
echo "Test 8: Incremental build falls back to full rebuild on failure"

# Create a mock that fails incremental but succeeds full
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "2.3.6"
  exit 0
fi
if [ "$1" = "build" ]; then
  if echo "$@" | grep -q "\-\-incremental"; then
    echo "incremental-build-failed" >&2
    exit 1
  else
    echo "full-build-fallback"
    mkdir -p .code-review-graph
    echo "fake-db" > .code-review-graph/graph.db
    exit 0
  fi
fi
if [ "$1" = "stats" ]; then
  echo "Nodes: 42, Edges: 87"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"

# Pre-create graph DB
mkdir -p .code-review-graph
echo "old-db" > .code-review-graph/graph.db

PATH="${mock_bin}:${PATH}" \
  OPENCODE_REVIEW_REPORT_GRAPH_BASE_REF="origin/main" \
  bash "${LIB_DIR}/build-code-graph.sh" > "${tmp_dir}/test8.out" 2>&1 || {
    cat "${tmp_dir}/test8.out"
    fail "Test 8: should succeed via fallback"
  }
grep -q "full-build-fallback" "${tmp_dir}/test8.out" || {
  cat "${tmp_dir}/test8.out"
  fail "Test 8: should fall back to full rebuild when incremental fails"
}
pass "Test 8: fallback to full rebuild works"

# --- Cleanup ------------------------------------------------------------------
rm -rf .code-review-graph ci_temp

echo ""
echo "=========================================="
echo "All tests passed!"
echo "=========================================="
