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
# Usage: Called from pipeline-code-review-report.yml workflow
# Arguments: $1=TOTAL_CHUNKS $2=OPENCODE_MODEL_ID $3=REVIEW_TYPE $4=FROM_SHA $5=FILES_CHANGED $6=CURRENT_SHA $7=EXPERTISE_STATEMENT $8=LAST_FULL_REVIEW_STATUS $9=OPENCODE_VERSION_INFO $10=OPENCODE_VERSION_FOOTER
#
# $9/$10 are rendered by lib/check-versions.sh. They are passed positionally,
# not read from the environment: this script runs as a child process, so an
# unexported variable set by a lib sourced into run-review.sh would silently
# be empty here.

TOTAL_CHUNKS="$1"
OPENCODE_MODEL_ID="$2"
REVIEW_TYPE="$3"
FROM_SHA="${4:-unknown}"
FILES_CHANGED="${5:-0}"
CURRENT_SHA="${6:-unknown}"
EXPERTISE_STATEMENT="$7"
LAST_FULL_REVIEW_STATUS="${8:-none}"
OPENCODE_VERSION_INFO="${9:-}"
OPENCODE_VERSION_FOOTER="${10:-}"

if [ -z "$TOTAL_CHUNKS" ] || [ -z "$OPENCODE_MODEL_ID" ] || [ -z "$EXPERTISE_STATEMENT" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: aggregate-reviews.sh TOTAL_CHUNKS OPENCODE_MODEL_ID REVIEW_TYPE [FROM_SHA] [FILES_CHANGED] [CURRENT_SHA] EXPERTISE_STATEMENT [LAST_FULL_REVIEW_STATUS] [OPENCODE_VERSION_INFO] [OPENCODE_VERSION_FOOTER]"
  exit 1
fi

echo "Last full review status: $LAST_FULL_REVIEW_STATUS"

# Fence hygiene: model output may contain nested/unbalanced code fences, which
# flip GFM fence parity and can swallow the <details> wrapper of the posted
# review into a literal code block (PR #36, review 4474042824). Every
# model-generated piece is balanced in place before being embedded.
. "$(dirname "${BASH_SOURCE[0]}")/lib/balance-fences.sh"

# Convert model ID to display name
get_model_display_name() {
  local model_id="$1"
  case "$model_id" in
    gemini-3.1-pro-preview)
      echo "Gemini 3.1 Pro Preview"
      ;;
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

get_provider_display_name() {
  case "${OPENCODE_REVIEW_REPORT_PROVIDER:-GEMINI}" in
    GEMINI)
      echo "Google Gemini"
      ;;
    COPILOT)
      echo "GitHub Copilot"
      ;;
    OPENAI)
      echo "OpenAI"
      ;;
    ANTHROPIC)
      echo "Anthropic"
      ;;
    OPENCODE-GO-OPENAI)
      echo "OpenCode Go (OpenAI surface)"
      ;;
    OPENCODE-GO-ANTHROPIC)
      echo "OpenCode Go (Anthropic surface)"
      ;;
    OPEN_ROUTER)
      echo "OpenRouter"
      ;;
    *)
      echo "${OPENCODE_REVIEW_REPORT_PROVIDER}"
      ;;
  esac
}

# $OPENCODE_MODEL_ID is the resolved review model (the chunk-review chain's
# winner). The posted `**Model:**` field shows it — chunk reviews drive the
# substantive findings, so that is the model users care about.
OPENCODE_MODEL_DISPLAY_NAME=$(get_model_display_name "$OPENCODE_MODEL_ID")
OPENCODE_PROVIDER_DISPLAY_NAME=$(get_provider_display_name)

# LADR-022: aggregation / summarisation is not deep analysis — run it on the
# cheap ORCHESTRATOR model, falling back to the resolved review model if the
# orchestrator is down (it is intentionally not probed at startup). The
# orchestrator id is an explicit, independently-tunable env var — no longer
# derived from the review model.
ORCHESTRATOR_MODEL_ID="${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-gemini-3-flash-preview}"

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
    # Balanced per chunk so one chunk's open fence cannot corrupt the next
    # chunk, the aggregation prompt, or the posted <details> section.
    balance_fences ci_temp/reviews/chunk_${i}.md
    cat ci_temp/reviews/chunk_${i}.md >> ci_temp/combined_reviews.md
    echo "" >> ci_temp/combined_reviews.md
  else
    echo "⚠️ Warning: Chunk ${i} review file not found"
  fi
done

echo "✅ Combined all chunk reviews"

# LADR-030 (supersedes LADR-017): the holistic / high-level aggregation now runs
# for EVERY PR, including single-chunk ones, so reviewers always get an aggregated
# Overall Summary, Issues Summary, Suggested Fixes and Recommendation — not just the
# raw per-file chunk findings. LADR-017 skipped this for `TOTAL_CHUNKS=1` on the
# premise that the pass was a ~15-min Pro-tier call with no cross-chunk surface; that
# rationale is stale (LADR-022 moved aggregation onto the cheap orchestrator/Flash
# model, ~30 s) and the missing high-level report was the visible gap users hit on
# small PRs. The two safety properties the old short-circuit enforced are preserved
# downstream regardless of chunk count: the fail-closed net (out-of-band
# chunk_<n>.failed flag files, LADR-031) catches any unreviewed chunk, and the
# workflow forces incremental reviews to COMMENT (never APPROVE) per LADR-004.

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

# LADR-030: aggregation runs for every PR. Phrase the chunk context honestly so a
# single-chunk PR is not described as "multiple chunks".
if [ "$TOTAL_CHUNKS" -eq 1 ]; then
  CHUNK_CONTEXT_INTRO="You are analyzing a pull request whose changes were reviewed in a single chunk. Aggregate that chunk's findings into a clear, high-level PR summary."
else
  CHUNK_CONTEXT_INTRO="You are analyzing a pull request that was reviewed in ${TOTAL_CHUNKS} chunks."
fi

cat > ci_temp/summary_prompt.txt << EOF
${EXPERTISE_STATEMENT}

${CHUNK_CONTEXT_INTRO}

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

**Important:** This PR's changes were reviewed in one or more chunks for memory efficiency; each chunk was reviewed independently. Your role is to:
1. Aggregate all issues from the chunk review(s)
2. Perform a HOLISTIC analysis looking for cross-cutting concerns, architectural issues, and patterns across the whole PR
3. Surface issues that become apparent when viewing all changes together (for multi-chunk PRs this includes issues that span chunks)

**Confidence Tag Handling:**
- Individual chunk reviews tag findings as `[VERIFIED]` (reviewer saw the code) or `[SPECULATIVE]` (inferred from partial context).
- **Preserve confidence tags** when aggregating issues into the summary. Copy the tag from the chunk review.
- **Do NOT elevate `[SPECULATIVE]` findings** to 🔴 Critical or 🟠 High Priority during aggregation. A speculative finding in a chunk stays speculative in the summary.
- Per LADR-019 you do NOT have file-system access at the aggregation step — chunk reviews already performed `read_file` verification for Critical/High findings. Tag promotion is not your responsibility.

**Review-Coverage Gaps Are NOT Code Issues (MANDATORY):**
- A file that was not included in any review chunk, a chunk that failed or timed out, or a PR-author focus area you could not verify is a REVIEW-COVERAGE GAP, not a code defect.
- **NEVER list a coverage gap under 🔴 Critical, 🟠 High, or 🟡 Medium.** Report it as 🔵 Low Priority informational only, tagged `[SPECULATIVE]` — you have not seen the code, so it can never be `[VERIFIED]`.
- **NEVER count coverage gaps in the Recommendation's Step 1 issue counts.** The pipeline's fail-closed safety net (LADR-031) handles failed chunks mechanically — re-flagging them as blocking issues double-counts the failure.
- This applies even when the PR author's AI Review Notes ask you to focus on that file or area: "I could not verify X" is 🔵 Low, never a blocking finding.

**Passing Checks Are NOT Issues (MANDATORY):**
- If a chunk review says a contract, file, setting, diagram, permission, or cross-file relationship is correct, treat it as positive context only.
- Do NOT copy "No issue", "consistent", "verified for consistency", "flagging only because checked", or similar passing-check notes into any Issues Summary severity section.
- Do NOT count passing checks in the Recommendation issue totals.

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
- **Missing implementations** (e.g., frontend changes without backend support, or vice versa) — based ONLY on the diffs the chunk reviews actually saw. "A file was not present in the review chunks" is a review-coverage gap (🔵 Low, `[SPECULATIVE]`), NOT a missing implementation
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

# Call the agent model via opencode for the aggregation summary
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
  bash "$(dirname "${BASH_SOURCE[0]}")/lib/report-error-log.sh" \
    "summary_generation" "ci_temp/summary_stderr.log" || true
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

# An open fence at the end of the main summary swallows the <details> tag that
# is appended right after it; one at the end of the detailed section swallows
# the chunk reviews. Balance both halves (the PR #36 breakage was main-side).
balance_fences ci_temp/pr_summary_main.md
balance_fences ci_temp/pr_summary_detailed.md

# Build final review comment with proper structure
# Format SHAs to 7 characters
SHORT_FROM_SHA="${FROM_SHA:0:7}"
SHORT_CURRENT_SHA="${CURRENT_SHA:0:7}"

# LADR-036: count failed chunks BEFORE the body is assembled so the posted body
# can carry a coverage banner that matches the fail-closed override at the end
# of this script. LADR-031: the signal is flag-file existence ONLY — NEVER grep
# review text for the failure marker (a quoted marker false-matched on PR #15).
FAILED_CHUNK_COUNT=$(ls ci_temp/reviews/chunk_*.failed 2>/dev/null | wc -l | tr -d ' ')

# LADR-055: render Part 1's Issues Summary from the merged structured findings
# instead of the orchestrator's free-text list, when — and only when — every
# chunk that actually reviewed something contributed a sidecar.
#
# The coverage precondition is the load-bearing part. Rendering from a PARTIAL
# set would silently drop the findings of any chunk whose model ignored the
# sidecar instruction: the review would still post, still look complete, and
# still be green, with entire chunks missing from the decision surface. That is
# the exact failure shape this whole change exists to avoid, so a partial set
# falls back to the pre-LADR-055 path in full. Failed chunks are excluded from
# the expectation, not counted against it — they contribute no findings by
# definition (LADR-031), and the coverage banner above already says so.
#
# Everything else about the posted body is unchanged: Part 2's collapsible
# <details> section still carries the verbatim chunk markdown, duplicates and
# all (LADR-005). Part 1 is the decision surface and benefits from dedup and
# stable numbering; Part 2 is the audit trail and must show what each chunk
# reviewer actually said.
FINDINGS_SUMMARY_APPLIED="false"
MERGED_FINDINGS_FILE="ci_temp/findings.merged.json"
if [ -s "$MERGED_FINDINGS_FILE" ]; then
  # Count chunks the merge actually ingested, not sidecar files on disk. A file
  # that exists but was rejected downstream — unparseable at the slurp, or a
  # document the merge helper counted as malformed — would otherwise be counted
  # as covered, and this precondition would wave through a summary that silently
  # omits that chunk while reporting full coverage. `merged_chunks` is the
  # merge's own answer to "whose findings are in here"; nothing else is.
  SIDECAR_COUNT=$(jq -r '(.merged_chunks // []) | length' "$MERGED_FINDINGS_FILE" 2>/dev/null || echo 0)
  EXPECTED_SIDECARS=$((TOTAL_CHUNKS - FAILED_CHUNK_COUNT))
  if [ "${EXPECTED_SIDECARS:-0}" -gt 0 ] && [ "${SIDECAR_COUNT:-0}" -eq "$EXPECTED_SIDECARS" ]; then
    if bash "$(dirname "${BASH_SOURCE[0]}")/lib/render-findings-summary.sh" \
         "$MERGED_FINDINGS_FILE" > ci_temp/issues_summary.md 2>/dev/null \
       && [ -s ci_temp/issues_summary.md ]; then
      # Replace the orchestrator's `## 🔍 Issues Summary` section — heading
      # through to the next `## ` heading — with the rendered one. Anything
      # outside that range (Overall Summary, Positive Highlights, Suggested
      # Fixes, Recommendation) is untouched and still comes from the orchestrator.
      #
      # INSERT when there is no such section to replace. Requiring one to exist
      # was a real defect: when the orchestrator's own summary call fails,
      # aggregate-reviews.sh substitutes a fallback template that has no
      # `## 🔍 Issues Summary` heading at all — so the replace-only path silently
      # discarded a healthy merged document. Observed on PR #106 run
      # 30756015689: the merge produced 5 findings and 1 suppressed, the summary
      # LLM failed, and the posted review carried no findings section whatsoever.
      # That is exactly backwards — a failed orchestrator is when deterministic,
      # already-validated findings matter most, not least. Insert before the
      # Recommendation (or append) so the section always has a home.
      if grep -q '^## 🔍 Issues Summary' ci_temp/pr_summary_main.md; then
        _fs_mode="replaced"
        awk -v render="ci_temp/issues_summary.md" '
          state == 0 && /^## 🔍 Issues Summary/ {
            state = 1
            while ((getline line < render) > 0) print line
            close(render)
            next
          }
          state == 1 && /^## / { state = 2 }
          state == 1 { next }
          { print }
        ' ci_temp/pr_summary_main.md > ci_temp/pr_summary_main.rendered.md
      elif grep -q '^## 🎯 Recommendation' ci_temp/pr_summary_main.md; then
        _fs_mode="inserted before Recommendation (orchestrator summary had no Issues Summary)"
        awk -v render="ci_temp/issues_summary.md" '
          done_it == 0 && /^## 🎯 Recommendation/ {
            while ((getline line < render) > 0) print line
            close(render)
            done_it = 1
          }
          { print }
        ' ci_temp/pr_summary_main.md > ci_temp/pr_summary_main.rendered.md
      else
        _fs_mode="appended (orchestrator summary had neither Issues Summary nor Recommendation)"
        cat ci_temp/pr_summary_main.md ci_temp/issues_summary.md \
          > ci_temp/pr_summary_main.rendered.md
      fi
      if [ -s ci_temp/pr_summary_main.rendered.md ]; then
        mv ci_temp/pr_summary_main.rendered.md ci_temp/pr_summary_main.md
        # The spliced-in section is our own markdown and cannot be unbalanced, but
        # the orchestrator's surrounding prose still can be — and the section we
        # removed may have been where its parity flipped. Re-balance.
        balance_fences ci_temp/pr_summary_main.md
        FINDINGS_SUMMARY_APPLIED="true"
        echo "✅ Issues Summary rendered from merged findings (${SIDECAR_COUNT}/${EXPECTED_SIDECARS} chunk sidecars) — ${_fs_mode}"
      else
        rm -f ci_temp/pr_summary_main.rendered.md
        echo "⚠️ Issues Summary splice produced no output — keeping the orchestrator's"
      fi
      unset _fs_mode
    else
      echo "⚠️ Could not render Issues Summary from merged findings — keeping the orchestrator's"
    fi
  else
    echo "ℹ️ Structured findings cover ${SIDECAR_COUNT:-0} of ${EXPECTED_SIDECARS:-0} reviewed chunk(s) — keeping the orchestrator's Issues Summary (partial coverage would drop findings)"
  fi
fi

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
EOF

# Version info block (CLI + provider package versions vs. npm latest).
# Rendered between the Model line and the coverage banner. Empty when the
# version check was skipped or failed (check-versions.sh is best-effort).
if [ -n "$OPENCODE_VERSION_INFO" ]; then
  echo "" >> ci_temp/final_review.md
  echo "$OPENCODE_VERSION_INFO" >> ci_temp/final_review.md
fi

# LADR-036: coverage banner. When any chunk failed, the fail-closed override at
# the end of this script forces REQUEST_CHANGES even if the Recommendation says
# APPROVE — say so in the body, so the posted state and the body never
# contradict (review 4465489664 posted an APPROVE-worded body as
# CHANGES_REQUESTED with no explanation).
if [ "${FAILED_CHUNK_COUNT:-0}" -gt 0 ]; then
  cat >> ci_temp/final_review.md << EOF

> ⚠️ **Review coverage incomplete:** ${FAILED_CHUNK_COUNT} of ${TOTAL_CHUNKS} chunk$([ "$TOTAL_CHUNKS" -ne 1 ] && echo "s" || echo "") failed to review (see the failed-chunk details below). Because part of the PR was not reviewed, this review is posted as **REQUEST CHANGES (fail-closed)** regardless of the Recommendation section. Re-run \`/ai-review\` to retry once the failure is addressed.
EOF
fi

cat >> ci_temp/final_review.md << EOF

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

# LADR-055 (D6.3): close the summary↔detail navigation gap. Part 1 is
# deduplicated and numbered; the sections below are each reviewer's raw output
# and are neither. Without this sentence a differing count between the two parts
# reads as a bug rather than as dedup working. The chunk back-reference on each
# numbered finding — "(chunk #3)" — names one of the `### Chunk #N` headings
# below, which is why those headings must stay stable and predictable.
if [ "$FINDINGS_SUMMARY_APPLIED" = "true" ]; then
  cat >> ci_temp/final_review.md << 'EOF'
> **Reading these against the summary:** the 🔍 Issues Summary above is deduplicated across chunks and numbered stably, and each finding names the chunk it came from. The sections below are what each chunk reviewer actually said, verbatim and unedited — so one numbered finding above may appear in several sections below, and findings the summary suppressed as low-confidence still appear here. The counts are meant to differ.

EOF
fi

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
*Automated review by [opencode](https://opencode.ai) using ${OPENCODE_PROVIDER_DISPLAY_NAME}*
*Model: ${OPENCODE_MODEL_DISPLAY_NAME} | Reviewed in $TOTAL_CHUNKS chunks*
EOF

# Compact CLI version line in the footer, pre-rendered by check-versions.sh.
# Empty when the version could not be determined.
if [ -n "$OPENCODE_VERSION_FOOTER" ]; then
  echo "$OPENCODE_VERSION_FOOTER" >> ci_temp/final_review.md
fi

echo ""
echo "✅ Final review comment prepared"

# Determine review action from summary
# First try to parse the machine-readable action field (more reliable)
REVIEW_DECISION=$(grep -i "^\*\*MACHINE_READABLE_ACTION:\*\*" ci_temp/pr_summary.md \
  | tail -1 \
  | sed -n 's/^.*\*\*MACHINE_READABLE_ACTION:\*\*[[:space:]]*\[\{0,1\}\([A-Za-z_][A-Za-z_]*\)\]\{0,1\}.*$/\1/p' \
  | tr '[:upper:]' '[:lower:]' \
  | tr -d '[:space:]')

# Fail-closed safety net: if ANY chunk failed to review, never APPROVE regardless
# of the summarizer's verdict — a failed chunk means part of the PR was not
# reviewed. This guards every PR, single- or multi-chunk, which is why LADR-030
# could safely drop the old single-chunk short-circuit. The LLM counts
# Critical/High findings and would otherwise treat a failure as "0 issues".
#
# LADR-031: the signal is OUT-OF-BAND — `review-in-chunks.sh` drops a
# `ci_temp/reviews/chunk_<n>.failed` flag file for any chunk it could not review.
# We do NOT grep the review TEXT for "## ⚠️ Review Failed": when this gate reviews
# its own repo, the review body legitimately QUOTES that marker (it's documented in
# SKILL.md and this script), and a text grep false-matched the quote → forced
# REQUEST_CHANGES on a clean APPROVE (observed on PR #15). A flag file cannot be
# quoted into existence by review content.
# LADR-036: FAILED_CHUNK_COUNT was computed from the same flag files before the
# body was assembled, so the coverage banner above and this override always agree.
if [ "${FAILED_CHUNK_COUNT:-0}" -gt 0 ]; then
  if [ "$REVIEW_DECISION" != "request_changes" ]; then
    echo "⚠️ ${FAILED_CHUNK_COUNT} chunk(s) failed to review — forcing REQUEST_CHANGES (fail-closed), overriding '${REVIEW_DECISION:-unknown}'."
    REVIEW_DECISION="request_changes"
  fi
fi

# LADR-055: the decision above is parsed from the ORCHESTRATOR's summary, which
# counts the Issues Summary it wrote. When we replaced that section with one
# rendered from the merged findings, the two can disagree — a Critical/High that
# every chunk reported but the orchestrator dropped would now be printed in the
# body under a posted APPROVE. That is precisely the body↔state contradiction
# LADR-036 exists to prevent, so escalate.
#
# This is deliberately one-directional. It can only turn approve/comment into
# request_changes; it can never turn request_changes into anything softer, so a
# cross-chunk finding the orchestrator raised holistically — which by definition
# has no per-chunk sidecar entry — still blocks. Structured findings can add a
# reason to block; they can never remove one.
if [ "${FINDINGS_SUMMARY_APPLIED:-false}" = "true" ] && [ "$REVIEW_DECISION" != "request_changes" ]; then
  BLOCKING_FINDING_COUNT=$(jq '[(.findings // [])[] | select(.severity == "critical" or .severity == "high")] | length' \
    "$MERGED_FINDINGS_FILE" 2>/dev/null || echo "INVALID")
  if [ "$BLOCKING_FINDING_COUNT" = "INVALID" ]; then
    # Cannot trust an unparseable count either way — preserve the orchestrator's
    # decision rather than silently treating a malformed file as "0 blocking".
    echo "⚠️ merged findings file is malformed — cannot count blocking findings, falling back to orchestrator decision"
    BLOCKING_FINDING_COUNT=0
  fi
  if [ "${BLOCKING_FINDING_COUNT:-0}" -gt 0 ]; then
    echo "⚠️ ${BLOCKING_FINDING_COUNT} Critical/High finding(s) in the rendered Issues Summary — forcing REQUEST_CHANGES, overriding '${REVIEW_DECISION:-unknown}' (body and posted state must agree)."
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
    # Check if there are ACTUAL critical/high issues (not just "None found" placeholders).
    # Extract the FULL body of each severity section (heading → next markdown heading),
    # not just the 2 trailing lines `grep -A2` would catch: a section can list several
    # multi-line issues separated by blank lines, which -A2 would silently undercount.
    # Tertiary fallback only — the machine-readable field and "REQUEST CHANGES" text
    # parse run first; issue/content lines never start with '#', so a '#'-prefixed line
    # is unambiguously the next heading and terminates the section.
    _section_body() { awk -v h="$1" 'index($0,h){g=1;next} g&&/^#/{g=0} g' ci_temp/pr_summary.md 2>/dev/null; }
    CRITICAL_ISSUES=$(_section_body "### 🔴 Critical Issues" | grep -vi "None found" | grep -v "^[[:space:]]*$" || true)
    HIGH_ISSUES=$(_section_body "### 🟠 High Priority Issues" | grep -vi "None found" | grep -v "^[[:space:]]*$" || true)
    if [ -n "$CRITICAL_ISSUES" ] || [ -n "$HIGH_ISSUES" ]; then
      echo "review_action=request_changes" >> "$GITHUB_OUTPUT"
      echo "📋 Recommendation: REQUEST CHANGES (critical/high issues found via content parsing)"
    elif grep -qiE "(decision|recommendation|machine_readable_action).*approve" ci_temp/pr_summary.md; then
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
