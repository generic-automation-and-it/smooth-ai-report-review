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

# --- Test 2: build-code-graph.sh version mismatch triggers pipx --force reinstall ---
echo ""
echo "Test 2: Version mismatch triggers pipx install --force (regression guard for the 'already installed' upgrade-path bug)"

# Track the "installed" version in a state file so the mocks can simulate real
# pipx behaviour: code-review-graph is already installed at 2.3.6 (a different
# version than requested), so a plain `pipx install` must fail exactly like
# real pipx does ("already installed"), and only `--force` may succeed. If a
# future change drops --force from build-code-graph.sh, this mock makes the
# install fail instead of silently letting a no-op mock mask the regression.
state_file="${tmp_dir}/mock_installed_version"
echo "2.3.6" > "$state_file"

cat > "${mock_bin}/code-review-graph" <<MOCK_EOF
#!/bin/bash
if [ "\$1" = "--version" ]; then
  cat "${state_file}"
  exit 0
fi
if [ "\$1" = "build" ]; then
  mkdir -p .code-review-graph
  echo "fake-db" > .code-review-graph/graph.db
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"

cat > "${mock_bin}/pipx" <<MOCK_EOF
#!/bin/bash
if [ "\$1" = "install" ]; then
  shift
  force="false"
  for arg in "\$@"; do
    [ "\$arg" = "--force" ] && force="true"
  done
  if [ "\$force" != "true" ]; then
    echo '"code-review-graph" is already installed at /root/.local/share/pipx/venvs/code-review-graph' >&2
    exit 1
  fi
  spec=""
  for arg in "\$@"; do spec="\$arg"; done
  echo "\${spec#*==}" > "${state_file}"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/pipx"

cat > "${mock_bin}/python3" <<'MOCK_EOF'
#!/bin/bash
# Mock python3: only used for pip install fallback, which we don't need
exit 0
MOCK_EOF
chmod +x "${mock_bin}/python3"

# Request 2.4.0 while the mock reports 2.3.6 already installed — this must
# now succeed via pipx install --force and report the new version.
PATH="${mock_bin}:${PATH}" \
  OPENCODE_REVIEW_REPORT_GRAPH_VERSION="2.4.0" \
  bash "${LIB_DIR}/build-code-graph.sh" > "${tmp_dir}/test2.out" 2>&1 || {
    cat "${tmp_dir}/test2.out"
    fail "Test 2: should succeed via pipx install --force when a different version is already installed"
  }
grep -q "code-review-graph ready (version: 2.4.0)" "${tmp_dir}/test2.out" || {
  cat "${tmp_dir}/test2.out"
  fail "Test 2: should reinstall and report the newly requested version"
}
pass "Test 2: version mismatch triggers pipx install --force and succeeds"

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

# Mock code-review-graph matching the REAL CLI (confirmed against the
# installed v2.3.7 binary — see .context/bug-detect-changes-format-flag.md):
# `detect-changes` has no `--format` flag at all; the bare invocation's
# stdout IS the JSON, using file_path/line_start/line_end (not file/line),
# no callers[]/tests[] on changed_functions, name (not function) on
# test_gaps, and context_savings.saved_percent (not savings_pct). The mock
# rejects `--format` exactly like the real CLI does, so a regression back
# to the old (wrong) assumption fails this test instead of passing it.
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "2.3.6"
  exit 0
fi
if [ "$1" = "detect-changes" ]; then
  if echo "$@" | grep -q -- "--format"; then
    echo "error: unrecognized arguments: --format" >&2
    exit 2
  fi
  cat <<'JSON_EOF'
{
  "changed_functions": [
    {
      "file_path": "src/controllers/order_controller.cs",
      "line_start": 42,
      "line_end": 60,
      "name": "ProcessOrder",
      "risk_score": 0.85
    },
    {
      "file_path": "src/services/pricing_service.cs",
      "line_start": 15,
      "line_end": 20,
      "name": "ValidatePrice",
      "risk_score": 0.45
    }
  ],
  "affected_flows": [
    {
      "name": "OrderSubmissionFlow",
      "criticality": "high",
      "node_count": 8
    },
    {
      "name": "PricingFlow",
      "criticality": "medium",
      "node_count": 4
    }
  ],
  "test_gaps": [
    {
      "file": "src/controllers/order_controller.cs",
      "line_start": 42,
      "name": "ProcessOrder"
    },
    {
      "file": "src/services/pricing_service.cs",
      "line_start": 15,
      "name": "ValidatePrice"
    }
  ],
  "context_savings": {
    "saved_percent": 82
  }
}
JSON_EOF
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

# Verify JSON output is the raw structured JSON, not a text-fallback wrapper
[ -s "ci_temp/graph_detect_changes.json" ] || fail "Test 6: JSON should be non-empty"
jq empty "ci_temp/graph_detect_changes.json" 2>/dev/null || {
  echo "JSON content:"
  cat "ci_temp/graph_detect_changes.json"
  fail "Test 6: JSON should be valid"
}
[ "$(jq -r '.format // "structured"' ci_temp/graph_detect_changes.json)" = "structured" ] || \
  fail "Test 6: JSON should be the real structured output, not a text-fallback wrapper"

# Verify summary was generated using the real field names
[ -s "ci_temp/graph_risk_summary.md" ] || fail "Test 6: summary should be non-empty"
grep -q "High-Risk Changed Functions" "ci_temp/graph_risk_summary.md" || fail "Test 6: summary should mention high-risk functions"
grep -q "ProcessOrder" "ci_temp/graph_risk_summary.md" || fail "Test 6: summary should mention ProcessOrder"
grep -q "src/controllers/order_controller.cs:42" "ci_temp/graph_risk_summary.md" || \
  fail "Test 6: high-risk line should use file_path:line_start, not file:line"
grep -q "Token savings: ~82%" "ci_temp/graph_risk_summary.md" || \
  fail "Test 6: summary should read context_savings.saved_percent, not savings_pct"

# Verify file risks (grouped by file_path)
[ -s "ci_temp/graph_file_risks.txt" ] || fail "Test 6: file risks should be non-empty"
grep -q "order_controller.cs" "ci_temp/graph_file_risks.txt" || fail "Test 6: should include order_controller.cs"

# Verify counts in output (regression guard for the FLOW_COUNT/GAP_COUNT
# "[.x // []] | length" bug, which always evaluated to 1 regardless of
# content — 2 items in each array here so that bug can't pass by coincidence)
grep -q "High-risk functions.*1" "${tmp_dir}/test6.out" || fail "Test 6: should report 1 high-risk function"
grep -q "Affected execution flows.*2" "${tmp_dir}/test6.out" || fail "Test 6: should report 2 affected flows"
grep -q "Test coverage gaps.*2" "${tmp_dir}/test6.out" || fail "Test 6: should report 2 test gaps"

pass "Test 6: full flow with mock produces correct output"

# --- Test 6b: detect-changes-graph.sh never passes --format to the CLI ------
echo ""
echo "Test 6b: detect-changes-graph.sh must not invoke detect-changes with --format (regression guard)"
grep -v '^\s*#' "${LIB_DIR}/detect-changes-graph.sh" | grep -q -- '--format' && \
  fail "Test 6b: detect-changes-graph.sh must not pass --format to detect-changes — that flag doesn't exist on the real CLI"
pass "Test 6b: no --format flag referenced"

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

# --- Test 9: run-review.sh re-exports PATH across the build/detect subshell boundary ---
echo ""
echo "Test 9: PATH re-export lets detect-changes-graph.sh find a pipx-installed binary (regression guard for the cross-subshell PATH bug)"

# Structural check: run-review.sh must actually contain a PATH re-export
# between the build-code-graph.sh and detect-changes-graph.sh invocations —
# the functional simulation below proves the mechanism works, but not that
# run-review.sh itself wires it in.
run_review_sh="${SCRIPT_DIR}/run-review.sh"
build_line="$(grep -n 'bash "\$LIB_DIR/build-code-graph\.sh"' "$run_review_sh" | head -1 | cut -d: -f1)"
detect_line="$(grep -n 'bash "\$LIB_DIR/detect-changes-graph\.sh"' "$run_review_sh" | head -1 | cut -d: -f1)"
export_line="$(sed -n "${build_line},${detect_line}p" "$run_review_sh" | grep -n 'export PATH="\$HOME/\.local/bin' | head -1 | cut -d: -f1)"
[ -n "$build_line" ] && [ -n "$detect_line" ] && [ -n "$export_line" ] || {
  fail "Test 9: run-review.sh must re-export \$HOME/.local/bin onto PATH between the build and detect subshell calls"
}

# A working code-review-graph mock, to be "installed" by the pipx mock below.
cat > "${mock_bin}/code-review-graph-real" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "2.3.6"
  exit 0
fi
if [ "$1" = "build" ]; then
  mkdir -p .code-review-graph
  echo "fake-db" > .code-review-graph/graph.db
  exit 0
fi
if [ "$1" = "detect-changes" ]; then
  echo "Changed functions: 0"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph-real"

# Simulate a real pipx install: a fake isolated HOME whose ~/.local/bin is NOT
# on the starting PATH (mirrors ubuntu-latest, where build-code-graph.sh's own
# subshell-local PATH export is invisible to the next `bash` invocation).
fake_home="${tmp_dir}/fake_home"
mkdir -p "${fake_home}/.local/bin"

cat > "${mock_bin}/pipx" <<MOCK_EOF
#!/bin/bash
# Mock pipx install: actually places a working code-review-graph binary at
# \$HOME/.local/bin, matching real pipx's install location.
if [ "\$1" = "install" ]; then
  cp "${mock_bin}/code-review-graph-real" "\$HOME/.local/bin/code-review-graph"
  chmod +x "\$HOME/.local/bin/code-review-graph"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/pipx"

# code-review-graph itself is deliberately absent from mock_bin here — pipx is
# the only way to get it, and it lands only in $HOME/.local/bin. Use a narrow
# base PATH (not the ambient $PATH) so a real code-review-graph install on the
# host machine can't mask the scenario being tested.
rm -f "${mock_bin}/code-review-graph"
pre_export_path="${mock_bin}:/usr/bin:/bin"

HOME="$fake_home" PATH="${pre_export_path}" \
  bash "${LIB_DIR}/build-code-graph.sh" > "${tmp_dir}/test9_build.out" 2>&1 || {
    cat "${tmp_dir}/test9_build.out"
    fail "Test 9: build-code-graph.sh should succeed by installing via pipx"
  }

# Confirm the bug premise: on the same PATH build-code-graph.sh started with,
# code-review-graph still isn't reachable — its own PATH export didn't leak.
HOME="$fake_home" PATH="${pre_export_path}" \
  bash -c 'command -v code-review-graph' >/dev/null 2>&1 && {
    fail "Test 9: code-review-graph should NOT be reachable without the fix (test setup invalid)"
  }

# Now run detect-changes-graph.sh exactly as run-review.sh's fixed Step 13.5
# does: re-export $HOME/.local/bin onto PATH after build-code-graph.sh, before
# the next subshell invocation.
mkdir -p .code-review-graph
echo "fake-db" > .code-review-graph/graph.db
post_export_path="${fake_home}/.local/bin:${pre_export_path}"
HOME="$fake_home" PATH="${post_export_path}" MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test9_detect.out" 2>&1 || {
    cat "${tmp_dir}/test9_detect.out"
    fail "Test 9: detect-changes-graph.sh should succeed once PATH is re-exported"
  }
grep -q "code-review-graph not found on PATH" "${tmp_dir}/test9_detect.out" && {
  cat "${tmp_dir}/test9_detect.out"
  fail "Test 9: detect-changes-graph.sh should find the pipx-installed binary after PATH re-export"
}
pass "Test 9: PATH re-export makes the pipx-installed binary visible to detect-changes-graph.sh"

rm -rf .code-review-graph ci_temp

# --- Cleanup ------------------------------------------------------------------
rm -rf .code-review-graph ci_temp

echo ""
echo "=========================================="
echo "All tests passed!"
echo "=========================================="
