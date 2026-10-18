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

# Every test below drives build-code-graph.sh / detect-changes-graph.sh, which
# write `.code-review-graph/` and `ci_temp/` RELATIVE TO THE CURRENT DIRECTORY,
# and which reset between tests with `rm -rf ci_temp`. Run all of that inside a
# throwaway repo rather than wherever the caller happened to be.
#
# This is not cosmetic. Under ai-analyse's test gate (LADR-057) the suites run
# from the repo root, where the gate used to keep its own `ci_temp/test_gate/`
# state — so this suite deleted it mid-run and the next suite in sort order was
# reported as a phantom regression without ever executing. The gate now stages
# out-of-tree too; both halves are needed, since any suite could do this.
#
# A `git init` sandbox is sufficient: the only git the scripts under test need
# is `rev-parse --show-toplevel` for path relativization, and the base ref is
# handed to a mocked CLI rather than to real git.
sandbox="${tmp_dir}/sandbox"
mkdir -p "$sandbox"
git -c init.defaultBranch=main init -q "$sandbox"
cd "$sandbox"

cleanup() {
  cd / || true
  rm -rf "$tmp_dir"
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
  OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION="2.3.6" \
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
  OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION="2.4.0" \
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
#
# Path fields are emitted ABSOLUTE (resolved at mock runtime via git
# rev-parse), because that is what the real CLI does — an earlier version of
# this mock used relative paths and therefore could not catch the missing
# relativization in detect-changes-graph.sh. The assertions below require the
# rendered output to be repo-relative.
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
  # The real CLI reports absolute paths rooted at the repo it analysed.
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  cat <<JSON_EOF
{
  "changed_functions": [
    {
      "file_path": "$ROOT/src/controllers/order_controller.cs",
      "line_start": 42,
      "line_end": 60,
      "name": "ProcessOrder",
      "risk_score": 0.85
    },
    {
      "file_path": "$ROOT/src/services/pricing_service.cs",
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
      "file": "$ROOT/src/controllers/order_controller.cs",
      "line_start": 42,
      "name": "ProcessOrder"
    },
    {
      "file": "$ROOT/src/services/pricing_service.cs",
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

# --- Paths must be relativized against the repo root -------------------------
# The mock emits ABSOLUTE paths like the real CLI. Every rendered path must be
# repo-relative: the summary tables are unreadable otherwise (a CI runner's
# ~70-char prefix overflows the 60-char truncation), and graph_file_risks.txt
# is the join key for LADR-051 chunk grouping, which matches diff paths.
test6_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if grep -qF "${test6_root}/src/" "ci_temp/graph_file_risks.txt"; then
  cat "ci_temp/graph_file_risks.txt"
  fail "Test 6: graph_file_risks.txt paths must be repo-relative, not absolute"
fi
if grep -qF "${test6_root}/src/" "ci_temp/graph_risk_summary.md"; then
  fail "Test 6: summary paths must be repo-relative, not absolute"
fi
# Positive assertion: the risk file's first column starts at the repo-relative
# path, so a future consumer can join it against `git diff --name-only`.
cut -f1 "ci_temp/graph_file_risks.txt" | grep -qx "src/controllers/order_controller.cs" || {
  cat "ci_temp/graph_file_risks.txt"
  fail "Test 6: graph_file_risks.txt column 1 should be exactly 'src/controllers/order_controller.cs'"
}
# test_gaps[] uses .file (not .file_path) — relativized through the same path.
grep -q -- "- \`src/services/pricing_service.cs:15\`" "ci_temp/graph_risk_summary.md" || \
  fail "Test 6: test_gaps entries should render repo-relative file:line_start"

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
  OPENCODE_TOOL_CODE_REVIEW_GRAPH_BASE_REF="origin/main" \
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
  OPENCODE_TOOL_CODE_REVIEW_GRAPH_BASE_REF="origin/main" \
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

# --- Test 10: graph_review_signals.tsv (LADR-050) ---------------------------
# The derived artifact the chunk slice reads. Its whole value is that it is
# pre-joined and repo-relative: raw JSON keeps absolute paths and needs the
# test_gaps join re-done per consumer, and an empty column in a TSV silently
# shifts the next one under IFS.
echo ""
echo "Test 10: review signals TSV — columns, join, and the empty-risk contract"

mkdir -p .code-review-graph
echo "fake-db" > .code-review-graph/graph.db

# A fixture that forces every branch: a named match on risk, a named match with
# NO risk (the "-" column), a line_start-only match (the fallback), a function
# with no coverage claim, and a test_gaps entry for a function that is not in
# changed_functions at all.
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "2.3.6"; exit 0; fi
if [ "$1" = "detect-changes" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  cat <<JSON_EOF
{
  "changed_functions": [
    {"file_path": "$ROOT/src/hot.cs", "line_start": 42, "line_end": 60, "name": "Hot", "risk_score": 0.85},
    {"file_path": "$ROOT/src/norisk.cs", "line_start": 7, "line_end": 9, "name": "NoRisk"},
    {"file_path": "$ROOT/src/byline.cs", "line_start": 15, "line_end": 16, "name": "RenamedAway"},
    {"file_path": "$ROOT/src/zero.cs", "line_start": 1, "line_end": 2, "name": "Zero", "risk_score": 0},
    {"file_path": "$ROOT/src/nofields.cs", "line_start": 3},
    {"file_path": "$ROOT/src/qualified.cs", "line_start": 4, "line_end": 6, "qualified_name": "$ROOT/src/qualified.cs::Class::Alpha", "risk_score": 0.5},
    {"file_path": "/outside/repo.cs", "line_start": 1, "line_end": 2, "name": "Outside", "risk_score": 0.2},
    {"file_path": "$ROOT/../outside.cs", "line_start": 1, "line_end": 2, "name": "Traversal", "risk_score": 0.2},
    {"file_path": "$ROOT/src/invalid.cs", "line_start": 1, "line_end": 2, "name": "InvalidRisk", "risk_score": "high"},
    {"file_path": "$ROOT/src/overload.cs", "line_start": 10, "line_end": 12, "name": "Run", "risk_score": 0.4},
    {"file_path": "$ROOT/src/overload.cs", "line_start": 20, "line_end": 22, "name": "Run", "risk_score": 0.4}
  ],
  "test_gaps": [
    {"file": "$ROOT/src/hot.cs", "line_start": 42, "name": "Hot"},
    {"file": "$ROOT/src/norisk.cs", "line_start": 7, "name": "NoRisk"},
    {"file": "$ROOT/src/byline.cs", "line_start": 15, "name": "TotallyDifferentName"},
    {"file": "$ROOT/src/ghost.cs", "line_start": 1, "name": "NotAChangedFunction"},
    {"file": "$ROOT/src/qualified.cs", "line_start": 4, "qualified_name": "$ROOT/src/qualified.cs::Class::Alpha"},
    {"file": "$ROOT/src/overload.cs", "line_start": 20, "name": "Run"}
  ],
  "context_savings": {"saved_percent": 50}
}
JSON_EOF
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"

rm -rf ci_temp && mkdir -p ci_temp
PATH="${mock_bin}:${PATH}" MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test10.out" 2>&1 || {
    cat "${tmp_dir}/test10.out"; fail "Test 10: detect-changes should succeed"
}

SIG="ci_temp/graph_review_signals.tsv"
[ -s "$SIG" ] || { cat "${tmp_dir}/test10.out"; fail "Test 10: graph_review_signals.tsv should be written"; }

# Six columns on every row: an empty field would collapse under IFS and shift
# `untested` into `risk` in every consumer that reads this file.
_bad_cols="$(awk -F'\t' 'NF < 6 { print NR": "NF" columns" }' "$SIG")"
if [ -z "$_bad_cols" ]; then
  pass "Test 10: every signals row has all 6 tab-separated columns"
else
  printf '%s\n' "$_bad_cols" | sed 's/^/     /'
  fail "Test 10: a signals row has fewer than 6 columns"
fi

# risk_score absent -> "-", never empty. A genuine 0 must survive as 0, because
# jq's // treats 0 as truthy but a downstream truthiness check might not.
_hot_risk="$(awk -F'\t' '$1 == "src/hot.cs" { print $5 }' "$SIG")"
_norisk_risk="$(awk -F'\t' '$1 == "src/norisk.cs" { print $5 }' "$SIG")"
_zero_risk="$(awk -F'\t' '$1 == "src/zero.cs" { print $5 }' "$SIG")"
if [ "$_hot_risk" = "0.85" ] && [ "$_norisk_risk" = "-" ] && [ "$_zero_risk" = "0" ]; then
  pass "Test 10: risk renders 0.85 / - / 0 (absent is '-', a real zero survives)"
else
  fail "Test 10: risk column wrong — hot='${_hot_risk}' norisk='${_norisk_risk}' zero='${_zero_risk}'"
fi

# untested join: by name for Hot/NoRisk, by line_start fallback for RenamedAway
# (whose gap name differs), false for Zero, and no row invented for the gap
# that names a function outside changed_functions.
_hot_u="$(awk -F'\t' '$1 == "src/hot.cs" { print $6 }' "$SIG")"
_byline_u="$(awk -F'\t' '$1 == "src/byline.cs" { print $6 }' "$SIG")"
_zero_u="$(awk -F'\t' '$1 == "src/zero.cs" { print $6 }' "$SIG")"
if [ "$_hot_u" = "true" ] && [ "$_byline_u" = "true" ] && [ "$_zero_u" = "false" ]; then
  pass "Test 10: untested joins by name and by line_start fallback, false when uncovered"
else
  fail "Test 10: untested join wrong — hot='${_hot_u}' byline='${_byline_u}' zero='${_zero_u}'"
fi
grep -q 'src/ghost.cs' "$SIG" && fail "Test 10: a test gap outside changed_functions must not become a row"

# Repo-relative, like graph_file_risks.txt: the slice joins this against diff paths.
t10_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if grep -qF "${t10_root}/src/" "$SIG"; then
  cat "$SIG"
  fail "Test 10: signals paths must be repo-relative, not absolute"
fi

# Risk-descending: the slice takes head -N, so the order is the contract.
_first="$(head -1 "$SIG" | cut -f1)"
if [ "$_first" = "src/hot.cs" ]; then
  pass "Test 10: rows are sorted risk-descending (0.85 first)"
else
  fail "Test 10: first row is '${_first}', expected src/hot.cs (sort is risk DESC)"
fi

# The three pre-existing artifacts must be untouched by this addition.
[ -s "ci_temp/graph_file_risks.txt" ] || fail "Test 10: graph_file_risks.txt regressed to empty"
[ -s "ci_temp/graph_risk_summary.md" ] || fail "Test 10: graph_risk_summary.md regressed to empty"
[ -s "ci_temp/graph_detect_changes.json" ] || fail "Test 10: graph_detect_changes.json regressed to empty"
pass "Test 10: signals TSV produced without disturbing the existing three artifacts"

# This is the real vendor qualified_name shape, not a mock's convenient bare
# name. The TSV itself ships in an artifact: cleaning only the prompt is too late.
grep -qF "$t10_root" "$SIG" && fail "Test 10: absolute root leaked into the signals artifact"
awk -F'\t' '$1 == "src/qualified.cs" && $4 == "Class::Alpha" && $6 == "true" { found=1 }
  END { exit !found }' "$SIG" || fail "Test 10: qualified symbol or its coverage match was lost"
! grep -qE 'Outside|Traversal|InvalidRisk' "$SIG" || fail "Test 10: unsafe/invalid row entered the artifact"
pass "Test 10: artifact is repo-relative throughout, qualified names survive, invalid rows are omitted"
awk -F'\t' '$1 == "src/overload.cs" {
  if ($2 == 10 && $6 == "false") covered=1
  if ($2 == 20 && $6 == "true") gap=1
} END { exit !(covered && gap) }' "$SIG" || fail 'Test 10: duplicate symbol names misattribute a coverage gap'
pass 'Test 10: same-name functions do not borrow each other’s coverage gaps'

# Raw vendor JSON must remain byte-identical, not just parseable and nonempty.
PATH="${mock_bin}:${PATH}" "${mock_bin}/code-review-graph" detect-changes --base origin/main > "${tmp_dir}/test10.raw"
cmp -s "${tmp_dir}/test10.raw" ci_temp/graph_detect_changes.json || fail "Test 10: raw vendor JSON was changed"
pass "Test 10: raw vendor JSON is byte-identical"

# Zero gaps is the discriminating count case: grep -c prints 0 AND returns 1,
# so a careless `|| echo 0` produces two zeroes and splits the log message.
jq '.test_gaps = []' ci_temp/graph_detect_changes.json > "${tmp_dir}/covered.json"
cat > "${mock_bin}/code-review-graph" <<MOCK_EOF
#!/bin/bash
cat "${tmp_dir}/covered.json"
MOCK_EOF
PATH="${mock_bin}:${PATH}" MERGE_BASE_FOR_DIFF=origin/main \
  bash "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test10_covered.out" 2>&1
rows="$(wc -l < "$SIG" | tr -d ' ')"
grep -qx "  Review signals: ${rows} function(s), 0 without test coverage" "${tmp_dir}/test10_covered.out" || \
  fail 'Test 10: zero-gap count must be one complete log line'
! grep -q 'true$' "$SIG" || fail 'Test 10: no-gap input gained an untested marker'
pass 'Test 10: all-covered input preserves false markers and one zero count'

rm -rf .code-review-graph ci_temp

# --- Test 11: the signals file exists on every degraded path ----------------
# Five early returns in detect-changes-graph.sh, five chances to leave a
# consumer reading a file that was never created. Missing ≠ empty is invisible
# downstream: the slice treats both as "nothing to say", so a later edit can drop
# one truncation without any test noticing.
echo ""
echo "Test 11: graph_review_signals.tsv is truncated on every degradation path"

_paths=0
# (a) no CLI on PATH
rm -rf ci_temp
env -i PATH="/usr/bin:/bin" HOME="$HOME" MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" >/dev/null 2>&1 || true
[ -f "ci_temp/graph_review_signals.tsv" ] || fail "Test 11: signals file missing when the CLI is not on PATH"
_paths=$((_paths + 1))
# (b) no graph DB
rm -rf ci_temp && mkdir -p .code-review-graph && echo "fake-db" > .code-review-graph/graph.db && rm .code-review-graph/graph.db
env -i PATH="${mock_bin}:/usr/bin:/bin" HOME="$HOME" MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" >/dev/null 2>&1 || true
[ -f "ci_temp/graph_review_signals.tsv" ] || fail "Test 11: signals file missing when the graph DB is absent"
_paths=$((_paths + 1))
# (c) detect-changes itself fails
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "2.3.6"; exit 0; }
[ "$1" = "detect-changes" ] && { echo "boom" >&2; exit 1; }
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"
rm -rf ci_temp && mkdir -p .code-review-graph && echo "fake-db" > .code-review-graph/graph.db
PATH="${mock_bin}:${PATH}" MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" >/dev/null 2>&1 || true
[ -f "ci_temp/graph_review_signals.tsv" ] || fail "Test 11: signals file missing when detect-changes fails"
_paths=$((_paths + 1))
# (d) jq unavailable — the graph RAN and produced JSON, but nothing can parse
# it out. This is the only degraded path that needs a working CLI on PATH and
# still no jq, so the PATH keeps mock_bin and drops everything else. Invoking
# bash by absolute path matters: env -i with a stripped PATH cannot resolve the
# bare name `bash`, and rc 127 there is indistinguishable from a script bug.
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "2.3.6"; exit 0; }
if [ "$1" = "detect-changes" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '{"changed_functions":[{"file_path":"%s/src/a.cs","line_start":1,"line_end":2,"name":"A","risk_score":0.5}],"test_gaps":[]}\n' "$ROOT"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"
echo "fake-db" > .code-review-graph/graph.db
mkdir -p "${tmp_dir}/nojq_bin"
for t in awk sort head cat mkdir mktemp rm wc tr git grep sed basename dirname date; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "${tmp_dir}/nojq_bin/$t" 2>/dev/null || true
done
rm -rf ci_temp
env -i PATH="${mock_bin}:${tmp_dir}/nojq_bin" HOME="$HOME" MERGE_BASE_FOR_DIFF="origin/main" \
  "$(command -v bash)" "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test11_nojq.out" 2>&1 || true
if ! grep -q "jq not available" "${tmp_dir}/test11_nojq.out"; then
  cat "${tmp_dir}/test11_nojq.out"
  fail "Test 11: the no-jq path was not reached — this case is testing the wrong branch"
fi
[ -f "ci_temp/graph_review_signals.tsv" ] || fail "Test 11: signals file missing when jq is unavailable"
_paths=$((_paths + 1))
# (e) invalid JSON
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "2.3.6"; exit 0; }
[ "$1" = "detect-changes" ] && { printf 'not json at all'; exit 0; }
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"
rm -rf ci_temp && mkdir -p .code-review-graph && echo "fake-db" > .code-review-graph/graph.db
PATH="${mock_bin}:${PATH}" MERGE_BASE_FOR_DIFF="origin/main" \
  bash "${LIB_DIR}/detect-changes-graph.sh" >/dev/null 2>&1 || true
[ -f "ci_temp/graph_review_signals.tsv" ] || fail "Test 11: signals file missing when the graph JSON is invalid"
_paths=$((_paths + 1))

# (f) jq present but failing. Distinct from (d): the graph ran, the JSON is
# valid, and the PARSER is what breaks. This is the path that must not leave a
# half-written artifact behind — a pipeline's exit status is its last command's,
# so `jq … | sort > out || : > out` never reaches the fallback when jq dies.
mkdir -p "${tmp_dir}/badjq_bin"
for t in awk sort head cat mkdir mktemp rm wc tr git grep sed basename dirname date; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "${tmp_dir}/badjq_bin/$t" 2>/dev/null || true
done
real_jq="$(command -v jq)"
cat > "${tmp_dir}/badjq_bin/jq" <<MOCK_EOF
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    *'def safe_text:'*)
      printf 'src/partial.cs\t1\t2\tPartial\t0.5\ttrue\n'
      exit 3 ;;
  esac
done
exec "$real_jq" "\$@"
MOCK_EOF
chmod +x "${tmp_dir}/badjq_bin/jq"
cat > "${mock_bin}/code-review-graph" <<'MOCK_EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "2.3.6"; exit 0; }
if [ "$1" = "detect-changes" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '{"changed_functions":[{"file_path":"%s/src/a.cs","line_start":1,"line_end":2,"name":"A","risk_score":0.5}],"test_gaps":[]}\n' "$ROOT"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "${mock_bin}/code-review-graph"
rm -rf ci_temp && mkdir -p .code-review-graph && echo "fake-db" > .code-review-graph/graph.db
rc_f=0
env -i PATH="${mock_bin}:${tmp_dir}/badjq_bin" HOME="$HOME" MERGE_BASE_FOR_DIFF="origin/main" \
  "$(command -v bash)" "${LIB_DIR}/detect-changes-graph.sh" > "${tmp_dir}/test11_badjq.out" 2>&1 || rc_f=$?
if [ "${rc_f}" -ne 0 ]; then
  cat "${tmp_dir}/test11_badjq.out"
  fail "Test 11: a failing jq must not abort the run (rc=${rc_f})"
fi
[ -f "ci_temp/graph_review_signals.tsv" ] || fail "Test 11: signals file missing when jq fails"
grep -q 'signals TSV generation failed' "${tmp_dir}/test11_badjq.out" || \
  fail 'Test 11: failed-jq fixture never reached signals generation'
# Empty, not partial: the failing-jq path must produce a zero-byte file.
if [ -s "ci_temp/graph_review_signals.tsv" ]; then
  fail "Test 11: a failing jq left a partially-written signals file"
fi
# The operator-visible count must stay on ONE line. `grep -c … || echo 0`
# printed its own 0 and then a second one, breaking the line in two — on the
# all-covered path, which is the common one.
if grep -qx '  Review signals: 0 function(s), 0 without test coverage' "${tmp_dir}/test11_badjq.out"; then
  pass "Test 11: the signals count line is not split across lines"
else
  cat "${tmp_dir}/test11_badjq.out"
  fail "Test 11: the signals count line is broken across lines (the grep -c || echo 0 defect)"
fi
_paths=$((_paths + 1))

rm -rf .code-review-graph ci_temp
pass "Test 11: signals file exists on all ${_paths} degradation paths (empty = fail-open)"

# --- Test 12: graph-signals-slice.sh ---------------------------------------
# Offline by contract, so no opencode and no gh: the chunk reviewer is handed a
# static fragment and never gets to run this itself (LADR-029 denies it bash).
echo ""
echo "Test 12: graph-signals-slice.sh — selection, contract and cap"

SLICE="${LIB_DIR}/graph-signals-slice.sh"
[ -f "$SLICE" ] || fail "Test 12: lib/graph-signals-slice.sh is missing"

printf 'file_rel\tline_start\tline_end\tname\trisk\tuntested\n' > "${tmp_dir}/sig.tsv"
printf 'src/a.cs\t10\t20\tAlpha\t0.85\ttrue\n'   >> "${tmp_dir}/sig.tsv"
printf 'src/b.cs\t5\t6\tBeta\t-\tfalse\n'       >> "${tmp_dir}/sig.tsv"
printf 'src/c.cs\t1\t2\tGamma\t0.4\ttrue\n'     >> "${tmp_dir}/sig.tsv"
printf 'other/z.cs\t1\t2\tZed\t0.99\ttrue\n'     >> "${tmp_dir}/sig.tsv"

# Chunk membership, NUL-separated on stdin.
out="$(printf 'src/a.cs\0src/b.cs\0src/c.cs\0' | bash "$SLICE" "${tmp_dir}/sig.tsv")"
rc=$?
if [ "${rc}" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'src/a.cs:10' \
   && printf '%s' "$out" | grep -q 'risk 0.85' \
   && printf '%s' "$out" | grep -q 'no test coverage' \
   && ! printf '%s' "$out" | grep -q 'other/z.cs'; then
  pass "Test 12: the slice keeps only the chunk's files and renders risk + coverage"
else
  printf '%s\n' "$out" | sed 's/^/     /'
  fail "Test 12: slice selection/rendering wrong (rc=${rc})"
fi

# A function with no risk_score must not render "risk -" — that reads as a score.
if printf '%s' "$out" | grep -q '^`src/b.cs:5` Beta$'; then
  pass "Test 12: a function with no risk_score renders without a risk fragment"
else
  fail "Test 12: a missing risk_score must render bare, not as 'risk -'"
fi

# A covered function must never carry the coverage label.
if printf '%s' "$out" | awk '/src\/b\.cs/ && /no test coverage/ { bad = 1 } END { exit bad ? 1 : 0 }'; then
  pass "Test 12: a covered function is not labelled untested"
else
  fail "Test 12: a covered function (untested=false) is labelled untested"
fi

# Nothing to say -> exit 3, not 0 and not 1. The caller treats 0 as "emit".
# Each probe captures its own status: this suite runs under `set -e`, where a
# deliberate non-zero exit would abort the run before the assertion that is
# ABOUT that exit code ever executed.
slice_rc() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

rc="$(printf 'src/absent.cs\0' | { slice_rc bash "$SLICE" "${tmp_dir}/sig.tsv"; })"
[ "$rc" = "3" ] || fail "Test 12: exit code for 'no rows' must be 3 (got ${rc})"
rc="$(printf '' | { slice_rc bash "$SLICE" "${tmp_dir}/sig.tsv"; })"
[ "$rc" = "3" ] || fail "Test 12: exit code for 'no files given' must be 3 (got ${rc})"
: > "${tmp_dir}/empty.tsv"
rc="$(printf 'src/a.cs\0' | { slice_rc bash "$SLICE" "${tmp_dir}/empty.tsv"; })"
[ "$rc" = "3" ] || fail "Test 12: exit code for an empty signals file must be 3 (got ${rc})"
rc="$(slice_rc bash "$SLICE" "${tmp_dir}/does-not-exist.tsv" < /dev/null)"
[ "$rc" = "1" ] || fail "Test 12: exit code for a missing signals file must be 1 (got ${rc})"
pass "Test 12: exit contract is 0 rows / 3 nothing-to-say / 1 unusable"

# A malformed row (too few columns) must be skipped, not rendered with a
# shifted coverage flag.
printf 'src/a.cs\t10\t20\tAlpha\n' > "${tmp_dir}/short.tsv"
rc="$(printf 'src/a.cs\0' | { slice_rc bash "$SLICE" "${tmp_dir}/short.tsv"; })"
[ "$rc" = "1" ] || fail "Test 12: a malformed matching row must be unusable (got ${rc})"
pass "Test 12: a malformed row rejects the slice rather than rendering shifted columns"

# The cap is real, and says what was cut. A bare ellipsis would read as a
# citation truncation, which is a different lie. 400 chunk files, so the slice
# has far more rows than the cap can hold.
: > "${tmp_dir}/big.tsv"
: > "${tmp_dir}/big_files"
i=0
while [ "${i}" -lt 400 ]; do
  printf 'src/f%03d.cs\t%d\t%d\tAVeryLongFunctionNameToForceTheCap\t0.%03d\ttrue\n' "${i}" "$((i + 1))" "$((i + 40))" "${i}" >> "${tmp_dir}/big.tsv"
  printf 'src/f%03d.cs\0' "${i}" >> "${tmp_dir}/big_files"
  i=$((i + 1))
done
big_out="$(OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES=512 \
  bash "$SLICE" "${tmp_dir}/big.tsv" < "${tmp_dir}/big_files")"
big_bytes="$(printf '%s' "$big_out" | wc -c | tr -d ' ')"
if [ "${big_bytes}" -le 512 ] && printf '%s' "$big_out" | grep -q 'truncated'; then
  pass "Test 12: the cap holds (${big_bytes} ≤ 512) including the truncation marker"
else
  fail "Test 12: cap not enforced (${big_bytes} bytes for a 512-byte cap) or no truncation marker"
fi

# A nonsense cap must fall back to the default, not become an unbounded slice.
bad_out="$(printf 'src/a.cs\0' | OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES="not-a-number" bash "$SLICE" "${tmp_dir}/sig.tsv")"
if [ "$?" -eq 0 ] && printf '%s' "$bad_out" | grep -q 'src/a.cs:10'; then
  pass "Test 12: a non-numeric cap falls back to the default instead of disabling the slice"
else
  fail "Test 12: a non-numeric cap must fall back to the default"
fi

# The rendered slice must never name a file the chunk did not ask about, and
# must never carry an absolute path (LADR-067's posted-body rule, upstream of it).
if printf '%s' "$out" | grep -qE '(/Users/|/home/|/tmp/)'; then
  fail "Test 12: the slice rendered an absolute path"
else
  pass "Test 12: no absolute path in the rendered slice"
fi

# The `name` column is qualified_name, which the real CLI renders as
# "<absolute repo prefix>/<repo-relative path>::<symbol>". Emitting it raw put a
# ~70-character /home/runner/work/... prefix in front of every function in the
# prompt — the exact leak the repo-relative contract exists to prevent, and the
# reason a mock fixture with bare names cannot be trusted on its own.
printf 'file_rel\tline_start\tline_end\tname\trisk\tuntested\n' > "${tmp_dir}/qname.tsv"
printf 'src/a.cs\t10\t20\t/srv/checkout/repo/src/a.cs::Alpha\t0.85\ttrue\n' >> "${tmp_dir}/qname.tsv"
printf 'src/b.cs\t5\t6\tBeta\t0.4\tfalse\n'                                       >> "${tmp_dir}/qname.tsv"
qout="$(printf 'src/a.cs\0src/b.cs\0' | bash "$SLICE" "${tmp_dir}/qname.tsv")"
if printf '%s' "$qout" | grep -q '`src/a.cs:10` Alpha' \
   && printf '%s' "$qout" | grep -q '`src/b.cs:5` Beta' \
   && ! printf '%s' "$qout" | grep -qE '/srv/checkout|::'; then
  pass "Test 12: a qualified_name's absolute prefix and :: separator are stripped"
else
  printf '%s\n' "$qout" | sed 's/^/     /'
  fail "Test 12: qualified_name leaked an absolute path or its :: separator"
fi

# Offline: no transport and no gh reachable from this lib. Comments are stripped
# first — the header documents the guarantee by naming the very commands it
# forbids, so a naive grep would flag the contract as the violation.
if grep -v '^[[:space:]]*#' "$SLICE" | grep -qE '\bopencode\b|\bgh\b|curl '; then
  fail "Test 12: graph-signals-slice.sh references opencode/gh/curl — it must stay offline"
else
  pass "Test 12: the slice lib is offline (no opencode/gh/curl)"
fi

# --- Cleanup ------------------------------------------------------------------
rm -rf .code-review-graph ci_temp

echo ""
echo "=========================================="
echo "All tests passed!"
echo "=========================================="
