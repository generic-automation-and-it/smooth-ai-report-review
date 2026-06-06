#!/bin/bash
set -e

# Requires Bash >= 4 (${VAR^^} uppercase expansion). On Bash 3.2 (macOS default)
# this crashes with "bad substitution" — fail fast instead.
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "❌ Requires Bash >= 4 (found ${BASH_VERSION:-unknown}). On macOS: 'brew install bash'." >&2
  exit 1
fi

# Script: aggregate-reviews.sh
# Purpose: Aggregate chunked reviews and generate PR summary
# Usage: Called from gemini-cli-code-review.yml workflow
# Arguments: $1=TOTAL_CHUNKS $2=OPENCODE_MODEL_ID $3=REVIEW_TYPE $4=FROM_SHA $5=FILES_CHANGED $6=CURRENT_SHA $7=EXPERTISE_STATEMENT $8=LAST_FULL_REVIEW_STATUS

TOTAL_CHUNKS="$1"
OPENCODE_MODEL_ID="$2"
REVIEW_TYPE="$3"
FROM_SHA="${4:-unknown}"
FILES_CHANGED="${5:-0}"
CURRENT_SHA="${6:-unknown}"
EXPERTISE_STATEMENT="$7"
LAST_FULL_REVIEW_STATUS="${8:-none}"

if [ -z "$TOTAL_CHUNKS" ] || [ -z "$OPENCODE_MODEL_ID" ] || [ -z "$EXPERTISE_STATEMENT" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: aggregate-reviews.sh TOTAL_CHUNKS OPENCODE_MODEL_ID REVIEW_TYPE [FROM_SHA] [FILES_CHANGED] [CURRENT_SHA] EXPERTISE_STATEMENT [LAST_FULL_REVIEW_STATUS]"
  exit 1
fi

echo "Last full review status: $LAST_FULL_REVIEW_STATUS"

# Convert model ID to display name
get_model_display_name() {
  local model_id="$1"
  case "$model_id" in
    gemini-3-pro)
      echo "Gemini 3 Pro"
      ;;
    gemini-3-pro-preview)
      echo "Gemini 3 Pro Preview"
      ;;
    gemini-2.5-pro)
      echo "Gemini 2.5 Pro"
      ;;
    gemini-2.5-pro-preview)
      echo "Gemini 2.5 Pro Preview"
      ;;
    gemini-3-flash-preview)
      echo "Gemini 3 Flash Preview"
      ;;
    gemini-2.5-flash)
      echo "Gemini 2.5 Flash"
      ;;
    *)
      echo "$model_id"
      ;;
  esac
}

# $OPENCODE_MODEL_ID is the resolved review model (the chunk-review chain's
# winner). The posted `**Model:**` field shows it — chunk reviews drive the
# substantive findings, so that is the model users care about.
OPENCODE_MODEL_DISPLAY_NAME=$(get_model_display_name "$OPENCODE_MODEL_ID")

# LADR-022: aggregation / summarisation is not deep analysis — run it on the
# cheap ORCHESTRATOR model, falling back to the resolved review model if the
# orchestrator is down (it is intentionally not probed at startup). The
# orchestrator id is an explicit, independently-tunable env var — no longer
# derived from the review model.
ORCHESTRATOR_MODEL_ID="${OPENCODE_MODEL_ORCHESTRATOR:-gemini-3-flash-preview}"

echo "Orchestrator model: $ORCHESTRATOR_MODEL_ID (review model was $OPENCODE_MODEL_ID)"

echo "=========================================="
echo "Aggregating $TOTAL_CHUNKS Chunk Reviews"
echo "=========================================="
echo ""

# Combine all chunk reviews (without header, will be added in final assembly)
cat > ci_temp/combined_reviews.md << 'EOF'
EOF

# Append each chunk review
for i in $(seq 0 $((TOTAL_CHUNKS - 1))); do
  if [ -f ci_temp/reviews/chunk_${i}.md ]; then
    if [ $i -gt 0 ]; then
      echo "---" >> ci_temp/combined_reviews.md
      echo "" >> ci_temp/combined_reviews.md
    fi
    echo "### Chunk #${i}" >> ci_temp/combined_reviews.md
    echo "" >> ci_temp/combined_reviews.md
    cat ci_temp/reviews/chunk_${i}.md >> ci_temp/combined_reviews.md
    echo "" >> ci_temp/combined_reviews.md
  else
    echo "⚠️ Warning: Chunk ${i} review file not found"
  fi
done

echo "✅ Combined all chunk reviews"

# LADR-017: Single-chunk short-circuit
# A 1-chunk PR has no cross-chunk surface to analyse — the holistic Gemini pass
# is pure overhead (~15 min on Pro). Build the summary programmatically from the
# chunk review's existing per-file priority findings instead.
if [ "$TOTAL_CHUNKS" -eq 1 ] && [ -f ci_temp/reviews/chunk_0.md ]; then
  echo "ℹ️ Single-chunk PR — skipping holistic Gemini call (LADR-017)"

  # Detect actual Critical/High findings (filter "None found" / "N/A" placeholders)
  # Anchor the placeholder match to ": (placeholder) <end-of-line>" so it doesn't
  # spuriously match "NA" inside words like "concatenated" with case-insensitive grep.
  HAS_CRITICAL_RAW=$(grep -E "^- 🔴 \[(VERIFIED|SPECULATIVE)\] Critical:" ci_temp/reviews/chunk_0.md 2>/dev/null | grep -vEi ": [\"'*]*(none found|n/a|not applicable)[\"'*.]*[[:space:]]*$" || true)
  HAS_HIGH_RAW=$(grep -E "^- 🟠 \[(VERIFIED|SPECULATIVE)\] High Priority:" ci_temp/reviews/chunk_0.md 2>/dev/null | grep -vEi ": [\"'*]*(none found|n/a|not applicable)[\"'*.]*[[:space:]]*$" || true)

  # Only count [VERIFIED] findings as blocking — [SPECULATIVE] cannot block (per LADR-012/LADR-015)
  HAS_CRITICAL=$(echo "$HAS_CRITICAL_RAW" | grep -E "\[VERIFIED\]" || true)
  HAS_HIGH=$(echo "$HAS_HIGH_RAW" | grep -E "\[VERIFIED\]" || true)

  if grep -q "## ⚠️ Review Failed" ci_temp/reviews/chunk_0.md 2>/dev/null; then
    # Fail-closed: the chunk produced a failure marker (empty/silent provider
    # failure, timeout, gateway down). Zero findings here means "we couldn't
    # review", NOT "clean" — never auto-approve a failed review.
    SC_ACTION="REQUEST_CHANGES"
    SC_DECISION="REQUEST CHANGES"
    SC_RATIONALE="Chunk review failed (empty/marker output) — could not certify the PR; not auto-approving."
  elif [ "$REVIEW_TYPE" = "incremental" ]; then
    # LADR-004: incremental reviews must never auto-resolve to APPROVE
    SC_ACTION="COMMENT"
    SC_DECISION="COMMENT"
    SC_RATIONALE="Incremental review — per LADR-004 only full reviews resolve to a final acceptance state."
  elif [ -n "$HAS_CRITICAL" ] || [ -n "$HAS_HIGH" ]; then
    SC_ACTION="REQUEST_CHANGES"
    SC_DECISION="REQUEST CHANGES"
    SC_RATIONALE="Verified Critical or High Priority findings present in chunk review."
  else
    SC_ACTION="APPROVE"
    SC_DECISION="APPROVE"
    SC_RATIONALE="No verified Critical/High findings in chunk review."
  fi

  # Generate a real Overall Summary via a targeted Flash call.
  # The short-circuit skips the full holistic aggregation, but a 2-3 sentence
  # narrative is still valuable and cheap on Flash (< 30 s).
  SC_OVERALL_SUMMARY="See per-file findings under \"Detailed Chunk Reviews\" below."
  {
    echo "Based on the following code review of a pull request, write 2-3 sentences describing:"
    echo "1. What this PR changes (the technical change)"
    echo "2. Why it is being made (the goal or benefit)"
    echo ""
    echo "Output ONLY the 2-3 sentences. No headers, no bullets, no code blocks."
    echo ""
    echo "---"
    echo ""
    cat ci_temp/reviews/chunk_0.md
  } > ci_temp/sc_summary_prompt.txt

  # LADR-023: opencode transport via the selected provider (default `gemini`).
  if bash "$(dirname "${BASH_SOURCE[0]}")/lib/opencode-with-fallback.sh" "$ORCHESTRATOR_MODEL_ID" "$OPENCODE_MODEL_ID" "" -- ci_temp/sc_summary_prompt.txt > ci_temp/sc_summary_raw.txt 2>/dev/null; then
    RAW_SUMMARY=$(grep -v "^$" ci_temp/sc_summary_raw.txt | head -c 600 || true)
    [ -n "$RAW_SUMMARY" ] && SC_OVERALL_SUMMARY="$RAW_SUMMARY"
  fi

  cat > ci_temp/pr_summary.md << EOF
## 📋 Overall Summary

${SC_OVERALL_SUMMARY}

## 🔍 Issues Summary

All findings (Critical / High / Medium / Low) are listed per file in the detailed chunk review below. No cross-chunk aggregation applies — this PR was reviewed as a single unit.

## 🎯 Recommendation

**Decision:** ${SC_DECISION}
**Rationale:** ${SC_RATIONALE}

**MACHINE_READABLE_ACTION:** ${SC_ACTION}

---
DETAILED_SECTION_MARKER
---

## 🔄 Holistic Cross-Chunk Analysis

Not applicable — this PR was reviewed as a single chunk.
EOF

  echo "✅ PR summary generated (programmatic, no LLM call)"
  echo "📋 Short-circuit recommendation: ${SC_DECISION}"

else

# Generate PR-level summary
echo "Generating PR summary..."

# Testing rules are now discovered dynamically via *AGENTS.md pattern (Implementation #89)
# No hardcoded path - Testing_Rules_AGENTS.md is found by find-context-files.sh

# Load PR description and extract AI Review Notes section
PR_DESCRIPTION=""
AI_REVIEW_NOTES=""
if [ -f "ci_temp/pr_description.txt" ]; then
  PR_DESCRIPTION=$(cat "ci_temp/pr_description.txt")
  echo "PR description loaded (${#PR_DESCRIPTION} chars)"

  # Extract AI Review Notes section (everything after "## AI Review Notes" header)
  # Uses awk instead of sed to handle case where AI Review Notes is the last section
  if echo "$PR_DESCRIPTION" | grep -q "## AI Review Notes"; then
    AI_REVIEW_NOTES=$(echo "$PR_DESCRIPTION" | awk '/^## AI Review Notes/{flag=1; next} /^## /{flag=0} flag' | sed '/^<!--/,/-->$/d' | sed '/^$/d')
    if [ -n "$AI_REVIEW_NOTES" ]; then
      echo "✅ AI Review Notes extracted for aggregation (${#AI_REVIEW_NOTES} chars)"
    fi
  fi
fi

cat > ci_temp/summary_prompt.txt << EOF
${EXPERTISE_STATEMENT}

You are analyzing a pull request that was reviewed in multiple chunks.

**Review Type:** ${REVIEW_TYPE^^}
EOF

# Add incremental review context if applicable
if [ "$REVIEW_TYPE" = "incremental" ]; then
  cat >> ci_temp/summary_prompt.txt << EOF

## ⚠️ CRITICAL: INCREMENTAL REVIEW LIMITATIONS

**This is an INCREMENTAL review** - you are only seeing CHANGES since the last review, NOT the full PR.

**Current PR Approval Status:** ${LAST_FULL_REVIEW_STATUS^^}
EOF

  # Add status-specific guidance
  if [ "$LAST_FULL_REVIEW_STATUS" = "APPROVED" ]; then
    cat >> ci_temp/summary_prompt.txt << 'EOF'
✅ **This PR has already been APPROVED by a full review.** The incremental review is only checking new changes.
- Do NOT say "a full review is required" or similar - the PR is already approved
- Only flag issues that are NEW in these specific changes
- The approval status should be maintained unless these new changes introduce critical/high issues
EOF
  elif [ "$LAST_FULL_REVIEW_STATUS" = "CHANGES_REQUESTED" ]; then
    cat >> ci_temp/summary_prompt.txt << 'EOF'
⚠️ **This PR has CHANGES_REQUESTED from a previous full review.** Issues may have been addressed in these changes.
- Note if the new changes appear to address previous concerns
- A new full review (/ai-review) is needed to clear the blocking status
EOF
  else
    cat >> ci_temp/summary_prompt.txt << 'EOF'
ℹ️ **No previous full review approval status found.** This may be a new PR or reviews were cleared.
EOF
  fi

  cat >> ci_temp/summary_prompt.txt << 'EOF'

**MANDATORY RULES for incremental reviews:**
1. You CANNOT make holistic claims about "missing implementations" or "missing integration" based on what you see
2. The full PR may have 13 files but you only see changes to 1 file - the other 12 were already reviewed
3. Per LADR-019 the aggregation step does NOT have \`read_file\` — symbol/file verification was already performed during the per-chunk review. Do NOT attempt file reads or claim you have verified anything against the current file state.
4. **NEVER flag "missing integration" as 🟠 High Priority** on incremental reviews — chunk reviews already gated High findings via \`read_file\`. Re-asserting it at aggregation is not adding new signal.
5. Integration concerns on incremental reviews should be 🔵 Low Priority informational notes at most

EOF
fi

# Add AI Review Notes if available
if [ -n "$AI_REVIEW_NOTES" ]; then
  cat >> ci_temp/summary_prompt.txt << EOF

## 📝 AI REVIEW NOTES (from PR author)

The PR author has provided the following guidance for this review:

${AI_REVIEW_NOTES}

**Important:** Consider these notes in your holistic analysis and recommendations.

EOF
fi

cat >> ci_temp/summary_prompt.txt << 'EOF'

**Your task:** Provide TWO sections:
1. A concise PR-level summary (for the main review body)
2. A detailed holistic analysis (to be placed with the individual chunk reviews)

**Important:** This PR was split into chunks for memory efficiency. Each chunk was reviewed independently without knowledge of other chunks. Your role is to:
1. Aggregate all issues from individual chunks
2. Perform a HOLISTIC analysis looking for cross-cutting concerns, architectural issues, and patterns across chunks
3. Identify issues that span multiple chunks or become apparent only when viewing all changes together

**Confidence Tag Handling:**
- Individual chunk reviews tag findings as `[VERIFIED]` (reviewer saw the code) or `[SPECULATIVE]` (inferred from partial context).
- **Preserve confidence tags** when aggregating issues into the summary. Copy the tag from the chunk review.
- **Do NOT elevate `[SPECULATIVE]` findings** to 🔴 Critical or 🟠 High Priority during aggregation. A speculative finding in a chunk stays speculative in the summary.
- Per LADR-019 you do NOT have file-system access at the aggregation step — chunk reviews already performed `read_file` verification for Critical/High findings. Tag promotion is not your responsibility.

**Required Output Format:**

## 📋 Overall Summary
[2-3 sentences about the PR as a whole - what is being changed and why]

## ✅ Positive Highlights
- [Good practices observed across chunks]
- [Well-written code examples]
- [Good architectural decisions]

## 🔍 Issues Summary

**Note:** Issues are categorized from BOTH individual chunk reviews AND holistic analysis. [📂 View detailed reviews below](#-view-detailed-reviews-click-to-expand)

### 🔴 Critical Issues
[List all critical issues found across ALL chunks AND from holistic analysis, with file references]
[Include cross-chunk issues that only become apparent when viewing the PR holistically]
[If none: "None found"]

### 🟠 High Priority Issues
[List all high priority issues found across ALL chunks AND from holistic analysis, with file references]
[Include integration issues, consistency problems, or architectural concerns]
[If none: "None found"]

### 🟡 Medium Priority Issues
[List medium priority issues or summarize common patterns from chunks AND holistic review]
[If none: "None found"]

### 🔵 Low Priority / Nitpicks
[List low priority issues or summarize common patterns]
[If none: "None found"]

## 📝 Suggested Fixes

**Purpose:** This section consolidates ALL suggested fixes from the individual chunk reviews to make it easy to see what needs to be changed without expanding the detailed reviews.

**Format for each fix:**
```
### `path/to/file.ext:line_number`
**Issue**: [Brief description of the issue] ([Priority emoji and level])
[Code block showing before/after with proper language syntax highlighting]
```

**Instructions:**
- Extract EVERY suggested fix from all chunk reviews below
- Include the file path with line numbers (use the format shown)
- Include the issue description with its priority emoji (🔴 🟠 🟡 🔵)
- Show the code fix with before/after comparison
- Use proper markdown code blocks with language identifiers (csharp, typescript, python, etc.)
- Group related fixes by file if there are multiple fixes for the same file
- Keep fixes in the same order they appear in chunks for easy cross-reference
- If no fixes were suggested in any chunk: write "None - all issues are architectural or require broader discussion"

[Extract and list all suggested fixes from the chunk reviews below]

## 🎯 Recommendation

**CRITICAL POLICY - You MUST follow this decision tree exactly:**

**Step 1: Count ACTUAL issues in your "Issues Summary" section above**
- Count of 🔴 Critical Issues: [number - DO NOT count "None found" as an issue]
- Count of 🟠 High Priority Issues: [number - DO NOT count "None found" as an issue]
- Count of 🟡 Medium Priority Issues: [number - DO NOT count "None found" as an issue]
- Count of 🔵 Low Priority Issues: [number - DO NOT count "None found" as an issue]

**IMPORTANT:** If a section says "None found", the count for that section is 0 (zero). Do NOT count "None found" as an issue.

**Examples:**
- ✅ Correct: 🔴 Critical says "None found" and 🟠 High says "None found" → Critical=0, High=0 → APPROVE
- ❌ Wrong: 🔴 Critical says "None found" but counted as 1 issue → REQUEST_CHANGES

**Step 2: Apply the decision rule (NO EXCEPTIONS):**
- IF (Critical count > 0 OR High Priority count > 0) → **MUST** use REQUEST_CHANGES
- ELSE IF (Medium count > 0 OR Low Priority count > 0) → **MUST** use APPROVE
- ELSE (no issues) → **MUST** use APPROVE

**Step 3: State your decision**

**Decision:** [APPROVE or REQUEST CHANGES]
**Rationale:** [State the rule you followed: "Following policy: [X] critical and [Y] high priority issues found - requesting changes" OR "Following policy: Only [X] medium and [Y] low priority issues found - approving"]

**MACHINE_READABLE_ACTION:** [APPROVE | REQUEST_CHANGES | COMMENT]

**Examples:**
- ✅ Correct: "2 medium issues → APPROVE"
- ✅ Correct: "1 critical issue → REQUEST_CHANGES"
- ❌ Wrong: "1 medium issue that I think is important → REQUEST_CHANGES" (Violates policy)
- ❌ Wrong: "No critical/high issues but many medium → REQUEST_CHANGES" (Violates policy)

---
DETAILED_SECTION_MARKER
---

## 🔄 Holistic Cross-Chunk Analysis
EOF

# Sync mode: narrowed holistic analysis for release branch sync PRs
if [ "${REVIEW_MODE:-standard}" = "sync" ]; then
  cat >> ci_temp/summary_prompt.txt << 'EOF'

**Purpose:** This is a **release branch sync PR**. All code changes were previously reviewed in their original PRs. This analysis focuses ONLY on issues introduced by the merge/sync process itself.

**What we looked for:**
- **Merge conflict resolution errors** — Corrupted code, duplicated blocks, lost changes, or mangled syntax from incorrect conflict resolution
- **Cross-PR breaking combinations** — Changes from separate PRs that are individually correct but incompatible when combined (e.g., removed method still called by another PR's code, conflicting signatures)
- **Configuration/environment drift** — appsettings, feature flags, or env vars that were overridden or lost during the sync
- **Migration ordering conflicts** — EF migrations with conflicting model snapshots or overlapping migration IDs

**Explicitly DO NOT flag:** Coding style, naming, test coverage gaps, performance suggestions, documentation drift, refactoring opportunities, or any issue that would have been caught in the original PR review.

**Severity threshold:** Only use 🔴 Critical and 🟠 High. Classify anything below that as 🔵 Low (informational only). Do NOT use 🟡 Medium for sync reviews.

**Cross-Chunk Issues Found:**

🔴 **Critical Issues**
[List any merge/sync issues. If none: "None found"]

🟠 **High Priority Issues**
[List any cross-PR breaking combinations. If none: "None found"]

🔵 **Low Priority / Informational**
[List any minor observations. If none: "None found"]

**Overall Assessment:** [Brief summary of sync-specific concerns or "No merge/sync issues identified — safe to merge."]
EOF

else
  # Standard/migration/docs-only holistic analysis
  cat >> ci_temp/summary_prompt.txt << 'EOF'

**Purpose:** This analysis views the PR as a unified whole, looking beyond individual chunk reviews for cross-cutting concerns.

**What we looked for:**
- Architectural patterns or anti-patterns across chunks
- Consistency issues between different parts of the codebase
- Breaking changes that affect multiple areas
- Security implications that span multiple files
- Performance impacts when all changes are considered together
- Cross-layer field consistency — entity fields reflected in DTOs, API responses, and frontend models across chunks
- API contract breaking changes — removed/renamed fields, changed response types that could break existing consumers (frontend or external integrations)
EOF

  # Add integration-related checks only for FULL reviews
  if [ "$REVIEW_TYPE" = "full" ]; then
    cat >> ci_temp/summary_prompt.txt << 'EOF'
- **Missing implementations** (e.g., frontend changes without backend support, or vice versa)
- **Integration concerns**: Verify new code is properly called/integrated into the application
- **Dependency Injection**: New classes and interfaces must be properly registered in DI container
- **Test Coverage**: Every code change should have corresponding tests added or updated
- **Concurrency safety**: Patterns where changes across chunks introduce shared state access or parallel execution on the same DbContext/resource (DR-008). Flag as High Priority if multiple chunks show coordinated async patterns without DbContext isolation.
EOF
  else
    cat >> ci_temp/summary_prompt.txt << 'EOF'

**⚠️ INCREMENTAL REVIEW LIMITATION:** This is an incremental review - you only see changes since the last review.
- Do NOT flag "missing integration" or "missing implementation" as High Priority
- Per LADR-019, file-system verification belongs to the chunk-review step, not aggregation. If a chunk review didn't flag it, do not invent it here.
- Integration concerns at the aggregation step are 🔵 Low Priority informational only
EOF
  fi

  cat >> ci_temp/summary_prompt.txt << 'EOF'

**Cross-Chunk Issues Found:**

🔴 **Critical Issues**
[List any critical cross-chunk issues. If none: "None found"]

🟠 **High Priority Issues**
[List any high priority cross-chunk issues. If none: "None found"]

🟡 **Medium Priority Issues**
[List any medium priority cross-chunk issues. If none: "None found"]

🔵 **Low Priority / Nitpicks**
[List any low priority cross-chunk issues. If none: "None found"]

**Additional Analysis:**
- **Consistency:** [Note any consistency issues across chunks]
EOF

  # LADR-020: Skip Integration / DI / Test Coverage sections on small PRs.
  # Per-chunk reviews already evaluate these on the changed files they see.
  # Re-asking the aggregation model to re-derive them on ≤2 chunks is duplicate
  # work — those concerns are intra-chunk, not cross-chunk.
  if [ "$REVIEW_TYPE" = "full" ] && [ "$TOTAL_CHUNKS" -gt 2 ]; then
    cat >> ci_temp/summary_prompt.txt << 'EOF'
- **Integration:** [Describe how chunks integrate together - verify new code is called in startup/entry points]
- **Dependency Injection Analysis**: [List any new classes/interfaces and verify DI registration. If N/A: "Not applicable"]
- **Test Coverage Analysis**: [For each code change, verify corresponding test file exists and was updated. If N/A: "Not applicable"]
  - .NET: Look for *Test.cs, *Tests.cs files matching changed code files
  - Frontend: Look for *.spec.ts files matching changed TypeScript files
  - Python: Look for test_*.py files matching changed Python files
EOF
  fi

  cat >> ci_temp/summary_prompt.txt << 'EOF'

**Overall Assessment:** [Brief summary of cross-chunk concerns or "No significant cross-chunk concerns identified."]
EOF

fi  # end sync/standard branch

cat >> ci_temp/summary_prompt.txt << 'EOF'

---

EOF

# Testing rules are discovered via standard *AGENTS.md pattern (Implementation #89)
# Testing_Rules_AGENTS.md will be included in chunk context if test files are changed

cat >> ci_temp/summary_prompt.txt << 'EOF'

**IMPORTANT - Individual Chunk Reviews for Reference:**

The following individual chunk reviews are provided for your reference to perform the holistic analysis above.
**DO NOT include these chunk reviews in your output** - they will be added separately by the script.
Your output should END after the "Overall Assessment" section above.

---

EOF

cat ci_temp/combined_reviews.md >> ci_temp/summary_prompt.txt

# Call the Gemini model via opencode for the aggregation summary
# (LADR-022: aggregation runs on the ORCHESTRATOR model, falling back to the
#  resolved review model; LADR-023: opencode transport).
agg_ok=true
bash "$(dirname "${BASH_SOURCE[0]}")/lib/opencode-with-fallback.sh" "$ORCHESTRATOR_MODEL_ID" "$OPENCODE_MODEL_ID" "" -- ci_temp/summary_prompt.txt > ci_temp/pr_summary.md 2>ci_temp/summary_stderr.log || agg_ok=false
# opencode can exit 0 while producing empty/tiny output (silent provider failure).
# Without this, an empty pr_summary.md slips past the success branch and the posted
# review loses its Overall Summary / Issues Summary / Recommendation entirely
# (only "No holistic analysis section found" remains). Treat empty as failure so the
# fail-safe REQUEST_CHANGES fallback below kicks in instead of a blank overview.
agg_size=$(wc -c < ci_temp/pr_summary.md 2>/dev/null || echo 0)
if [ "$agg_ok" = "true" ] && [ "${agg_size:-0}" -lt 50 ]; then
  agg_ok=false
fi
if [ "$agg_ok" = "true" ]; then
  echo "✅ PR summary generated successfully (model: $ORCHESTRATOR_MODEL_ID)"
else
  echo "❌ Summary generation failed/empty - using fallback"
  if [ -s "ci_temp/summary_stderr.log" ]; then
    echo "📋 Stderr log: ci_temp/summary_stderr.log"
  fi
  cat > ci_temp/pr_summary.md << EOF
## 📋 Overall Summary
This PR was reviewed in $TOTAL_CHUNKS chunks. Summary generation encountered an error.
Please review the detailed chunk reviews below.

## 🎯 Recommendation
**Decision:** REQUEST CHANGES (failed to generate summary - review manually)
**Rationale:** Summary generation failed - manual review required for safety

**MACHINE_READABLE_ACTION:** REQUEST_CHANGES
EOF
fi

fi  # end TOTAL_CHUNKS=1 short-circuit (LADR-017)

# Split the summary into main section and detailed section
if grep -q "DETAILED_SECTION_MARKER" ci_temp/pr_summary.md; then
  # Extract main summary (before marker)
  sed '/DETAILED_SECTION_MARKER/,$d' ci_temp/pr_summary.md > ci_temp/pr_summary_main.md

  # Extract detailed holistic analysis (after marker)
  sed -n '/DETAILED_SECTION_MARKER/,$p' ci_temp/pr_summary.md | sed '1,3d' > ci_temp/pr_summary_detailed.md
else
  # Fallback if marker not found (backward compatibility)
  cp ci_temp/pr_summary.md ci_temp/pr_summary_main.md
  echo "## 🔄 Holistic Cross-Chunk Analysis" > ci_temp/pr_summary_detailed.md
  echo "No holistic analysis section found." >> ci_temp/pr_summary_detailed.md
fi

# Build final review comment with proper structure
# Format SHAs to 7 characters
SHORT_FROM_SHA="${FROM_SHA:0:7}"
SHORT_CURRENT_SHA="${CURRENT_SHA:0:7}"

cat > ci_temp/final_review.md << EOF
## 🤖 OpenCode CLI Code Review - Commit: \`${SHORT_CURRENT_SHA}\`

\`\`\`
█▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
█░░█ █░░█ █▀▀▀ █░░█ █░░░ █░░█ █░░█ █▀▀▀
▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀  ▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀
\`\`\`

**Review Type:** ${REVIEW_TYPE^^}
EOF

# Add "Changes Since" for incremental reviews
if [ "$REVIEW_TYPE" = "incremental" ]; then
  cat >> ci_temp/final_review.md << EOF
**Changes Since:** \`${SHORT_FROM_SHA}\`
EOF
fi

cat >> ci_temp/final_review.md << EOF
**Files Changed:** ${FILES_CHANGED}
EOF

if [ -f ci_temp/excluded_files.txt ] && [ -s ci_temp/excluded_files.txt ]; then
  EXCLUDED_COUNT=$(wc -l < ci_temp/excluded_files.txt | tr -d ' ')
  echo "**Files Excluded:** ${EXCLUDED_COUNT} (auto-generated/lock files)" >> ci_temp/final_review.md
fi

cat >> ci_temp/final_review.md << EOF
**Reviewed in:** ${TOTAL_CHUNKS} chunk$([ "$TOTAL_CHUNKS" -ne 1 ] && echo "s" || echo "")
**Model:** ${OPENCODE_MODEL_DISPLAY_NAME}

---

EOF

# Add main summary
cat ci_temp/pr_summary_main.md >> ci_temp/final_review.md

# Add collapsible detailed section
cat >> ci_temp/final_review.md << EOF

---

<details>
<summary><b>📂 View Detailed Reviews</b> (click to expand)</summary>

EOF

# Add holistic analysis with header
cat ci_temp/pr_summary_detailed.md >> ci_temp/final_review.md

echo "" >> ci_temp/final_review.md
echo "---" >> ci_temp/final_review.md
echo "" >> ci_temp/final_review.md

# Add individual chunk reviews with header
cat >> ci_temp/final_review.md << EOF
## 📂 Detailed Chunk Reviews

This PR was reviewed in **$TOTAL_CHUNKS chunk$([ "$TOTAL_CHUNKS" -ne 1 ] && echo "s" || echo "")** to manage memory efficiently.

EOF

cat ci_temp/combined_reviews.md >> ci_temp/final_review.md

# Add AI Review Context Documents section
echo "" >> ci_temp/final_review.md
echo "---" >> ci_temp/final_review.md
echo "" >> ci_temp/final_review.md
echo "## 📚 AI Review Context Documents" >> ci_temp/final_review.md
echo "" >> ci_temp/final_review.md
echo "The following \`*AGENTS.md\` context files were provided to guide this review:" >> ci_temp/final_review.md
echo "" >> ci_temp/final_review.md

# Use all_context_files.txt collected from chunks (Implementation #90)
if [ -f ci_temp/all_context_files.txt ] && [ -s ci_temp/all_context_files.txt ]; then
  while IFS= read -r context_file; do
    echo "- \`${context_file}\`" >> ci_temp/final_review.md
  done < ci_temp/all_context_files.txt
else
  echo "- *No context files found for this PR*" >> ci_temp/final_review.md
fi

echo "" >> ci_temp/final_review.md

cat >> ci_temp/final_review.md << EOF

</details>

---
*Automated review by [opencode](https://opencode.ai) using Google Gemini*
*Model: ${OPENCODE_MODEL_DISPLAY_NAME} | Reviewed in $TOTAL_CHUNKS chunks*
EOF

echo ""
echo "✅ Final review comment prepared"

# Determine review action from summary
# First try to parse the machine-readable action field (more reliable)
REVIEW_DECISION=$(grep -i "^\*\*MACHINE_READABLE_ACTION:\*\*" ci_temp/pr_summary.md | sed 's/.*\*\*MACHINE_READABLE_ACTION:\*\*[[:space:]]*\[\?\([A-Z_]*\)\]\?.*/\1/' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

# Fail-closed safety net (multi-chunk): if ANY chunk failed to review (failure
# marker present in the combined reviews), never APPROVE regardless of the
# summarizer's verdict — a failed chunk means part of the PR was not reviewed.
# Complements the single-chunk guard (LADR-017 short-circuit). The LLM counts
# Critical/High findings and would otherwise treat a failure marker as "0 issues".
if grep -q "## ⚠️ Review Failed" ci_temp/combined_reviews.md 2>/dev/null; then
  if [ "$REVIEW_DECISION" != "request_changes" ]; then
    echo "⚠️ A chunk failed to review — forcing REQUEST_CHANGES (fail-closed), overriding '${REVIEW_DECISION:-unknown}'."
    REVIEW_DECISION="request_changes"
  fi
fi

if [ "$REVIEW_DECISION" = "request_changes" ]; then
  echo "review_action=request_changes" >> "$GITHUB_OUTPUT"
  echo "📋 Recommendation: REQUEST CHANGES (from machine-readable field)"
elif [ "$REVIEW_DECISION" = "approve" ]; then
  echo "review_action=approve" >> "$GITHUB_OUTPUT"
  echo "📋 Recommendation: APPROVE (from machine-readable field)"
elif [ "$REVIEW_DECISION" = "comment" ]; then
  echo "review_action=comment" >> "$GITHUB_OUTPUT"
  echo "📋 Recommendation: COMMENT (from machine-readable field)"
else
  # Fallback to parsing text/emojis if machine-readable field isn't present or is unclear
  echo "⚠️ Machine-readable action not found or unclear, falling back to text parsing"
  if grep -qi "REQUEST CHANGES" ci_temp/pr_summary.md; then
    echo "review_action=request_changes" >> "$GITHUB_OUTPUT"
    echo "📋 Recommendation: REQUEST CHANGES (from text parsing)"
  else
    # Check if there are ACTUAL critical/high issues (not just "None found" placeholders)
    CRITICAL_ISSUES=$(grep -A2 "### 🔴 Critical Issues" ci_temp/pr_summary.md 2>/dev/null | grep -vi "None found" | grep -vi "^### " | grep -vi "^--$" | grep -v "^$" || true)
    HIGH_ISSUES=$(grep -A2 "### 🟠 High Priority Issues" ci_temp/pr_summary.md 2>/dev/null | grep -vi "None found" | grep -vi "^### " | grep -vi "^--$" | grep -v "^$" || true)
    if [ -n "$CRITICAL_ISSUES" ] || [ -n "$HIGH_ISSUES" ]; then
      echo "review_action=request_changes" >> "$GITHUB_OUTPUT"
      echo "📋 Recommendation: REQUEST CHANGES (critical/high issues found via content parsing)"
    elif grep -qi "APPROVE" ci_temp/pr_summary.md; then
      echo "review_action=approve" >> "$GITHUB_OUTPUT"
      echo "📋 Recommendation: APPROVE (from text parsing)"
    else
      echo "review_action=comment" >> "$GITHUB_OUTPUT"
      echo "📋 Recommendation: COMMENT (unclear from summary)"
    fi
  fi
fi

echo ""
echo "=========================================="
echo "Aggregation Complete"
echo "=========================================="
