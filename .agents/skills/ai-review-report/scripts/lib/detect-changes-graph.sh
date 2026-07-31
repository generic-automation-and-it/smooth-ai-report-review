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
#   head_sha            — current HEAD SHA (set by run-review.sh Step 4)
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

# --- Tunables -----------------------------------------------------------------
# Top-N caps for downstream LADR-050/051/052 consumers. Adjust here to widen
# or narrow the per-chunk / per-flow context windows without touching the
# jq pipelines below.
readonly TOP_N_FILE_RISKS=10
readonly TOP_N_HIGH_RISK=10

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

# --- Run detect-changes -------------------------------------------------------
# The CLI outputs JSON to stdout. Capture it and also produce a brief summary.
ANALYSIS_START="$(date +%s)"

# Try the JSON output first; fall back to brief text if JSON format is unavailable
if code-review-graph detect-changes --base "$BASE_REF" --format json \
    > "$WORK_DIR/graph_detect_changes.json" 2>"$WORK_DIR/graph_detect_changes_stderr.log"; then
  echo "✓ detect-changes completed (JSON output)"
elif code-review-graph detect-changes --base "$BASE_REF" \
    > "$WORK_DIR/graph_detect_changes_brief.txt" 2>"$WORK_DIR/graph_detect_changes_stderr.log"; then
  echo "✓ detect-changes completed (text output — JSON format not available)"
  # Wrap text output in a minimal JSON structure for downstream compatibility.
  # Use jq --arg so a $BASE_REF containing quotes or backslashes is escaped
  # safely rather than interpolated as raw text.
  jq -n --arg base "$BASE_REF" --arg raw "$(cat "$WORK_DIR/graph_detect_changes_brief.txt")" \
    '{format: "text-fallback", raw_output: $raw, base_ref: $base}' \
    > "$WORK_DIR/graph_detect_changes.json"
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
# The JSON structure from detect-changes includes:
#   - changed_functions[]: each with risk_score, file, line, callers[], tests[]
#   - affected_flows[]: execution flows impacted by changes
#   - test_gaps[]: high-risk functions without test coverage
#   - context_savings: token reduction estimates
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

# Check if this is a text-fallback structure (no structured fields)
FORMAT="$(jq -r '.format // "structured"' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "structured")"
if [ "$FORMAT" = "text-fallback" ]; then
  echo "ℹ️  Graph output is text-fallback format — limited structured analysis available"
  # Extract what we can from the raw text
  cat > "$WORK_DIR/graph_risk_summary.md" <<EOF
## 🔗 Code Graph Analysis

*Graph analysis completed in ${ANALYSIS_TIME}s. Structured parsing unavailable — see raw output below.*

<details>
<summary>Raw detect-changes output</summary>

\`\`\`
$(jq -r '.raw_output // "no output"' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null | head -100)
\`\`\`

</details>
EOF
  : > "$WORK_DIR/graph_file_risks.txt"
  exit 0
fi

# --- Structured analysis (JSON with expected fields) -------------------------
echo "Parsing graph analysis results..."

# Per-file risk scores: extract max risk per file for chunk grouping
# Output format: filepath<TAB>risk_score<TAB>changed_function_count
jq -r '
  .changed_functions // [] |
  group_by(.file) |
  .[] |
  {
    file: .[0].file,
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
FLOW_COUNT="$(jq '[.affected_flows // []] | length' \
  "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo 0)"
echo "  Affected execution flows: ${FLOW_COUNT}"

# Count test gaps
GAP_COUNT="$(jq '[.test_gaps // []] | length' \
  "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo 0)"
echo "  Test coverage gaps: ${GAP_COUNT}"

# Token savings estimate
SAVINGS_PCT="$(jq -r '.context_savings.savings_pct // "unknown"' \
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
    jq -r --argjson n "$TOP_N_HIGH_RISK" '
      .changed_functions // [] |
      [.[] | select((.risk_score // 0) >= 0.7)] |
      sort_by(-.risk_score) |
      .[:$n] |
      .[] |
      "- `\(.file):\(.line // "?")` — `\(.name // "unknown")` risk: \(.risk_score)" +
      (if (.callers // [] | length) > 0 then " (\(.callers | length) callers)" else "" end) +
      (if (.tests // [] | length) == 0 then " ⚠️ NO TESTS" else "" end)
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
    jq -r '
      .test_gaps // [] |
      .[:10] |
      .[] |
      "- `\(.file // "?")` — `\(.function // "unknown")` (risk: \(.risk_score // "?"))"
    ' "$WORK_DIR/graph_detect_changes.json" 2>/dev/null || echo "  *(parsing failed)*"
    echo ""
  fi

  # Per-file risk summary (top N)
  if [ -s "$WORK_DIR/graph_file_risks.txt" ]; then
    echo "### 📊 Per-File Risk Summary (top ${TOP_N_FILE_RISKS})"
    echo ""
    echo "| File | Max Risk | Changed Functions |"
    echo "|------|----------|-------------------|"
    head -n "$TOP_N_FILE_RISKS" "$WORK_DIR/graph_file_risks.txt" | while IFS=$'\t' read -r file risk count; do
      # Truncate long file paths
      display_file="$file"
      if [ "${#display_file}" -gt 60 ]; then
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
