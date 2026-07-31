#!/bin/bash
# detect-changes-graph.sh — run code-review-graph detect-changes and produce
# risk-scored analysis for the chunked review pipeline.
#
# Called from run-review.sh Step 13.5 after the graph is built (build-code-graph.sh).
# Produces:
#   ci_temp/graph_detect_changes.json  — raw JSON from detect-changes (for Phase 2/3)
#   ci_temp/graph_risk_summary.md      — human-readable risk summary (for aggregation)
#   ci_temp/graph_file_risks.txt       — per-file risk scores (for chunk grouping)
#
# Inputs (env vars):
#   MERGE_BASE_FOR_DIFF — git ref to diff against (set by run-review.sh Step 9)
#
# Exit codes:
#   0 — success (analysis produced, even if empty)
#   1 — hard failure (caller should skip graph enrichment)
#
# Graceful degradation: if code-review-graph is not installed or detect-changes
# fails, this script logs a warning and exits 0 with empty output files. The
# caller (run-review.sh) checks for file existence before using graph data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="ci_temp"

# Ensure work directory exists
mkdir -p "$WORK_DIR"

# --- Preflight ----------------------------------------------------------------
if ! command -v code-review-graph >/dev/null 2>&1; then
  echo "⚠️  code-review-graph not found on PATH — skipping graph analysis" >&2
  : > "$WORK_DIR/graph_detect_changes.json"
  : > "$WORK_DIR/graph_risk_summary.md"
  : > "$WORK_DIR/graph_file_risks.txt"
  exit 0
fi

if [ ! -d ".code-review-graph" ] || [ ! -f ".code-review-graph/graph.db" ]; then
  echo "⚠️  Code graph not built — skipping detect-changes analysis" >&2
  : > "$WORK_DIR/graph_detect_changes.json"
  : > "$WORK_DIR/graph_risk_summary.md"
  : > "$WORK_DIR/graph_file_risks.txt"
  exit 0
fi

# --- Resolve base ref ---------------------------------------------------------
BASE_REF="${MERGE_BASE_FOR_DIFF:-}"
if [ -z "$BASE_REF" ]; then
  # Fall back to origin/main or HEAD~1
  if git rev-parse --verify "origin/main" >/dev/null 2>&1; then
    BASE_REF="origin/main"
  else
    BASE_REF="HEAD~1"
  fi
fi
echo "Running detect-changes against base: ${BASE_REF}"

# --- Resolve repo root for path relativization --------------------------------
# The CLI emits ABSOLUTE file paths (confirmed against v2.3.7 — `file_path` on
# changed_functions, `file` on test_gaps). Two reasons we strip the repo root
# before rendering:
#   1. On a CI runner the prefix is ~70 chars
#      (/home/runner/work/<repo>/<repo>/...), which blows past the 60-char
#      truncation below and cuts exactly the informative tail.
#   2. graph_file_risks.txt is the join key for graph-aware chunk grouping
#      (LADR-051), which matches against repo-relative diff paths.
# ltrimstr is a no-op when the prefix doesn't match (e.g. a symlinked checkout
# where git's toplevel and the CLI's path differ), so this degrades gracefully
# to the previous absolute-path behaviour rather than mangling anything.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPO_PREFIX="${REPO_ROOT%/}/"

# --- Run detect-changes -------------------------------------------------------
# `detect-changes` has no `--format` flag — its default (unflagged) stdout
# output IS the structured JSON (see .context/bug-detect-changes-format-flag.md
# for how this was discovered and confirmed against the installed CLI).
# `--brief` produces a human-readable summary instead, which we don't want here.
ANALYSIS_START="$(date +%s)"

if code-review-graph detect-changes --base "$BASE_REF" \
    > "$WORK_DIR/graph_detect_changes.json" 2>"$WORK_DIR/graph_detect_changes_stderr.log"; then
  echo "✓ detect-changes completed (JSON output)"
else
  echo "⚠️  detect-changes failed — skipping graph enrichment" >&2
  cat "$WORK_DIR/graph_detect_changes_stderr.log" 2>/dev/null | head -10 || true
  : > "$WORK_DIR/graph_detect_changes.json"
  : > "$WORK_DIR/graph_risk_summary.md"
  : > "$WORK_DIR/graph_file_risks.txt"
  exit 0
fi

ANALYSIS_END="$(date +%s)"
ANALYSIS_TIME=$((ANALYSIS_END - ANALYSIS_START))

# --- Parse and produce summaries ----------------------------------------------
# The real detect-changes JSON schema (confirmed against code-review-graph
# v2.3.7 output, not assumed — see .context/bug-detect-changes-format-flag.md):
#   - changed_functions[]: id, kind, name, qualified_name, file_path,
#     line_start, line_end, language, parent_name, is_test, risk_score.
#     No callers[] or tests[] field — test coverage lives in test_gaps[]
#     instead, and is not attached per-function here.
#   - review_priorities[]: same shape as changed_functions[], pre-sorted by
#     the tool's own priority ranking (not consumed here yet — see the bug
#     doc's "possible future improvements" section).
#   - affected_flows[]: execution flows impacted by changes
#   - test_gaps[]: functions without test coverage — name, qualified_name,
#     file (NOT file_path — the field name is inconsistent with
#     changed_functions/review_priorities), line_start, line_end. No
#     risk_score on these entries.
#   - context_savings: {estimated, saved_tokens, saved_percent}
#
# All path fields (changed_functions[].file_path, test_gaps[].file) are
# ABSOLUTE. We relativize them against REPO_PREFIX at render time — see the
# "Resolve repo root" block above for why.
#
# We extract per-file risk scores for chunk grouping and produce a markdown
# summary for the aggregation prompt.

# Check if jq is available for JSON parsing
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  jq not available — cannot parse graph JSON (producing empty summaries)" >&2
  : > "$WORK_DIR/graph_risk_summary.md"
  : > "$WORK_DIR/graph_file_risks.txt"
  exit 0
fi

# Validate JSON is non-empty and parseable
if [ ! -s "$WORK_DIR/graph_detect_changes.json" ] || ! jq empty "$WORK_DIR/graph_detect_changes.json" 2>/dev/null; then
  echo "⚠️  Graph JSON empty or invalid — skipping summary generation" >&2
  : > "$WORK_DIR/graph_risk_summary.md"
  : > "$WORK_DIR/graph_file_risks.txt"
  exit 0
fi

# --- Structured analysis (JSON with expected fields) -------------------------
echo "Parsing graph analysis results..."

# Per-file risk scores: extract max risk per file for chunk grouping
# Output format: filepath<TAB>risk_score<TAB>changed_function_count
# Paths are emitted REPO-RELATIVE so LADR-051 can join them against diff paths.
jq -r --arg root "$REPO_PREFIX" '
  .changed_functions // [] |
  group_by(.file_path) |
  .[] |
  {
    file: (.[0].file_path // "?" | ltrimstr($root)),
    max_risk: ([.[].risk_score // 0] | max),
    func_count: length
  } |
  "\(.file)\t\(.max_risk)\t\(.func_count)"
' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null | sort -t$'\t' -k2 -rn \
  > "$WORK_DIR/graph_file_risks.txt" || true

FILE_COUNT="$(wc -l < "$WORK_DIR/graph_file_risks.txt" 2>/dev/null | tr -d ' ')"
echo "  Files with changed functions: ${FILE_COUNT:-0}"

# Count high-risk functions (risk >= 0.7)
HIGH_RISK_COUNT="$(jq '[.changed_functions // [] | .[] | select((.risk_score // 0) >= 0.7)] | length' \
  "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo 0)"
echo "  High-risk functions (≥0.7): ${HIGH_RISK_COUNT}"

# Count affected execution flows
FLOW_COUNT="$(jq '.affected_flows // [] | length' \
  "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo 0)"
echo "  Affected execution flows: ${FLOW_COUNT}"

# Count test gaps
GAP_COUNT="$(jq '.test_gaps // [] | length' \
  "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo 0)"
echo "  Test coverage gaps: ${GAP_COUNT}"

# Token savings estimate
SAVINGS_PCT="$(jq -r '.context_savings.saved_percent // "unknown"' \
  "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "unknown")"

# --- Build markdown summary ---------------------------------------------------
{
  echo "## 🔗 Code Graph Analysis"
  echo ""
  echo "*Analysis completed in ${ANALYSIS_TIME}s | Base: \`${BASE_REF}\` | Token savings: ~${SAVINGS_PCT}%*"
  echo ""

  # High-risk functions
  if [ "${HIGH_RISK_COUNT:-0}" -gt 0 ]; then
    echo "### 🔴 High-Risk Changed Functions (risk ≥ 0.7)"
    echo ""
    jq -r --arg root "$REPO_PREFIX" '
      .changed_functions // [] |
      [.[] | select((.risk_score // 0) >= 0.7)] |
      sort_by(-.risk_score) |
      .[:10] |
      .[] |
      "- `\(.file_path // "?" | ltrimstr($root)):\(.line_start // "?")` — `\(.name // "unknown")` risk: \(.risk_score)"
    ' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "  *(parsing failed)*"
    echo ""
  fi

  # Affected execution flows
  if [ "${FLOW_COUNT:-0}" -gt 0 ]; then
    echo "### 🔀 Affected Execution Flows"
    echo ""
    jq -r '
      .affected_flows // [] |
      .[:5] |
      .[] |
      "- **\(.name // "unknown")** (criticality: \(.criticality // "?")): \(.node_count // 0) nodes"
    ' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "  *(parsing failed)*"
    echo ""
  fi

  # Test coverage gaps
  if [ "${GAP_COUNT:-0}" -gt 0 ]; then
    echo "### ⚠️ Test Coverage Gaps"
    echo ""
    jq -r --arg root "$REPO_PREFIX" '
      .test_gaps // [] |
      .[:10] |
      .[] |
      "- `\(.file // "?" | ltrimstr($root)):\(.line_start // "?")` — `\(.name // "unknown")`"
    ' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "  *(parsing failed)*"
    echo ""
  fi

  # Per-file risk summary (top 10)
  if [ -s "$WORK_DIR/graph_file_risks.txt" ]; then
    echo "### 📊 Per-File Risk Summary (top 10)"
    echo ""
    echo "| File | Max Risk | Changed Functions |"
    echo "|------|----------|-------------------|"
    head -10 "$WORK_DIR/graph_file_risks.txt" | while IFS=$'\t' read -r file risk count; do
      # Truncate long file paths
      display_file="$file"
      if [ "${#display_file}" -gt 60 ]; then
        # Bash 5 substring-from-end: keep the last 57 chars after a "..." prefix
        display_file="...${display_file: -57}"
      fi
      echo "| \`$display_file\` | ${risk} | ${count} |"
    done
    echo ""
  fi

  # Graph stats
  echo "<details>"
  echo "<summary>Graph Statistics</summary>"
  echo ""
  jq -r '
    "```\n" +
    "Total changed functions: " + ((.changed_functions // []) | length | tostring) + "\n" +
    "High-risk (≥0.7): " + ([.changed_functions // [] | .[] | select((.risk_score // 0) >= 0.7)] | length | tostring) + "\n" +
    "Affected flows: " + ((.affected_flows // []) | length | tostring) + "\n" +
    "Test gaps: " + ((.test_gaps // []) | length | tostring) + "\n" +
    "```"
  ' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "*(stats unavailable)*"
  echo ""
  echo "</details>"

} > "$WORK_DIR/graph_risk_summary.md"

echo ""
echo "✓ Graph analysis complete:"
echo "  JSON: $WORK_DIR/graph_detect_changes.json"
echo "  Summary: $WORK_DIR/graph_risk_summary.md"
echo "  File risks: $WORK_DIR/graph_file_risks.txt (${FILE_COUNT:-0} files)"
