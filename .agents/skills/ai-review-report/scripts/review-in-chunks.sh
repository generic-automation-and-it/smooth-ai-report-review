#!/bin/bash
set -e

# Requires Bash >= 4.3 (mapfile, wait -n concurrency throttle). On Bash 3.2
# (macOS default) mapfile yields empty arrays and `wait -n` is unavailable,
# which floods the gateway with unthrottled parallel calls — fail fast instead.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]}" = "4" ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
  echo "❌ Requires Bash >= 4.3 (found ${BASH_VERSION:-unknown}). On macOS: 'brew install bash'." >&2
  exit 1
fi

# Script: review-in-chunks.sh
# Purpose: Review PR changes in chunks to avoid memory issues
# Usage: Called from pipeline-code-review-report.yml workflow
# Arguments: $1=FROM_SHA $2=TO_SHA $3=OPENCODE_MODEL_ID $4=EXPERTISE_STATEMENT

FROM_SHA="$1"
TO_SHA="$2"
OPENCODE_MODEL_ID="$3"
EXPERTISE_STATEMENT="$4"

if [ -z "$FROM_SHA" ] || [ -z "$TO_SHA" ] || [ -z "$OPENCODE_MODEL_ID" ] || [ -z "$EXPERTISE_STATEMENT" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: review-in-chunks.sh FROM_SHA TO_SHA OPENCODE_MODEL_ID EXPERTISE_STATEMENT"
  exit 1
fi

echo "=========================================="
echo "Chunked Review: $FROM_SHA..$TO_SHA"
echo "Model: $OPENCODE_MODEL_ID"
echo "=========================================="
echo ""

# Per-chunk review budget. This wraps the WHOLE fallback chain
# (lib/opencode-with-fallback.sh has no internal timeout of its own), so when it
# fires the LADR-002 secondary model never gets to run — a timeout does not just
# fail the chunk, it silently disables the two-tier rescue that exists for
# exactly this case. Budget generously; the cost of a too-long timeout is a
# slower job, the cost of a too-short one is a fail-closed REQUEST_CHANGES on a
# chunk that would have reviewed fine.
#
# Default 450: raised from the original hardcoded 300, but deliberately NOT set
# as high as it could be. The 300 was calibrated before LADR-055 roughly tripled
# per-chunk model output and was demonstrably too tight (PR #106 killed a 96 KB
# chunk on the ceiling). Measured headroom on the deployed pair: the slowest
# chunk that ever SUCCEEDED took 209 s, so 450 is better than 2x the observed
# worst case.
#
# The ceiling is a deadlock detector as much as a budget. Past roughly this
# point a chunk is not "slow", it is stuck — a hung connection, a retry loop, a
# model that will never return — and waiting it out buys nothing while holding
# the job open. Failing at 450 and reporting it is more useful than succeeding
# at 800. If chunks legitimately need more, the fix is less output per chunk,
# not a higher ceiling.
#
# Chunks run in parallel, so the wall-clock cost is bounded by the slowest
# chunk, not their sum.
echo "⏱️  Per-chunk review timeout: ${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT}s"
echo ""

# LADR-055: structured findings — confidence anchors, the quote-the-line gate,
# and the machine-readable per-chunk sidecar. Enabled by default; a falsy
# OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS reverts the chunk prompt to
# its pre-LADR-055 shape exactly, which is what makes an eval A/B meaningful.
#
# The anchors and the sidecar are gated together on purpose. The anchors are only
# load-bearing because merge-findings.py enforces them mechanically (demotion
# without a quote, suppression below the actionable anchor); with the sidecar off
# there is nothing to enforce them, and unenforced rubric prose is prompt weight
# with an unmeasured effect on output.
#
# Same tokenized truthy test as the graph-analysis (LADR-049) and rtk (LADR-054)
# gates, so pathological values like `1true` land on the same side of the line
# everywhere.
structured_findings_enabled() {
  local v="${OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS:-1}"
  printf '%s' "${v,,}" | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'
}
if structured_findings_enabled; then
  echo "🧩 Structured findings enabled (LADR-055)"
else
  echo "🧩 Structured findings disabled (OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS)"
fi
echo ""

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
      echo "✅ AI Review Notes extracted (${#AI_REVIEW_NOTES} chars)"
    else
      echo "ℹ️ AI Review Notes section found but empty (only comments)"
    fi
  else
    echo "ℹ️ No AI Review Notes section in PR description"
  fi
else
  echo "ℹ️ PR description file not found"
fi
echo ""

# Create reviews directory
mkdir -p ci_temp/reviews

# Group files by parent directory and include related test files
echo "Grouping files by directory and matching test files..."
> ci_temp/file_groups.txt
> ci_temp/file_mapping.txt

# First pass: Create mapping of code files to test files
tr '\0' '\n' < ci_temp/changed_files.txt | while IFS= read -r file; do
  basename_file=$(basename "$file")
  dirname_file=$(dirname "$file")

  # Determine if this is a test file or code file, and find its pair
  is_test_file=false
  related_file=""

  # .NET test patterns: *Test.cs, *Tests.cs
  if [[ "$basename_file" =~ Test\.cs$ ]] || [[ "$basename_file" =~ Tests\.cs$ ]]; then
    is_test_file=true
    # Extract base name (remove Test/Tests.cs suffix)
    base_name=$(echo "$basename_file" | sed -E 's/(Test|Tests)\.cs$/.cs/')
    # Look for matching code file in ci_temp/changed_files.txt
    related_file=$(tr '\0' '\n' < ci_temp/changed_files.txt | grep -F "/${base_name}" | grep -v "Test\.cs$" | grep -v "Tests\.cs$" | head -1 || echo "")
  fi

  # Frontend test patterns: *.spec.ts
  if [[ "$basename_file" =~ \.spec\.ts$ ]]; then
    is_test_file=true
    # Extract base name (remove .spec.ts suffix)
    base_name=$(echo "$basename_file" | sed 's/\.spec\.ts$/.ts/')
    # Look for matching code file
    related_file=$(tr '\0' '\n' < ci_temp/changed_files.txt | grep -F "/${base_name}" | grep -v "\.spec\.ts$" | head -1 || echo "")
  fi

  # Python test patterns: test_*.py
  if [[ "$basename_file" =~ ^test_.*\.py$ ]]; then
    is_test_file=true
    # Extract base name (remove test_ prefix)
    base_name=$(echo "$basename_file" | sed 's/^test_//')
    # Look for matching code file
    related_file=$(tr '\0' '\n' < ci_temp/changed_files.txt | grep -F "/${base_name}" | head -1 || echo "")
  fi

  # Store mapping: test_file -> code_file
  if [ "$is_test_file" = true ] && [ -n "$related_file" ]; then
    echo "${file}::${related_file}" >> ci_temp/file_mapping.txt
  fi
done

# --- Semantic Business Context Grouping (LLM-based) ---
# Uses Gemini to group files by business context for better cross-cutting review
# Falls back to directory-based grouping if LLM grouping fails
SEMANTIC_GROUPING_THRESHOLD=15
SEMANTIC_GROUPING_SUCCESS=false
REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING="${OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING:-10}"
FORCE_SINGLE_CHUNK=false

if ! [[ "$REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING" =~ ^[0-9]+$ ]]; then
  echo "⚠️ Invalid OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING='${REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING}' (must be integer). Using default: 10"
  REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING=10
fi

file_count=$(bash "$(dirname "${BASH_SOURCE[0]}")/lib/count-changed-files.sh" ci_temp/changed_files.txt)
echo ""
echo "Files to review: ${file_count}"
echo "Single chunk threshold: ${REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING} files (OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING)"

# MAX_CHUNK_SIZE is the hard upper bound on per-chunk prompt size. It is
# referenced here so the single-chunk threshold is not the only signal —
# a few very large files can still build a prompt that exceeds the
# 5-minute model timeout (e.g. PR #86: 9 files but 208KB of diff →
# exit 124). When file_count is sub-threshold but the total diff
# exceeds the cap, fall through to adaptive splitting.
MAX_CHUNK_SIZE=102400  # 100KB diff size limit per chunk

# Compute the total diff size across all changed files. Only run the
# per-file `git diff` loop when the size-cap override could trigger —
# i.e. when file_count is at or below the single-chunk threshold. For
# larger PRs we already know we'll do adaptive splitting, so the
# size-cap is moot and the loop would just add 3-10s on a cold
# cache. PR #86 review 4820368853 #10.
total_diff_size=0
if [ "$file_count" -le "$REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING" ]; then
  while IFS= read -r -d '' _f; do
    [ -z "$_f" ] && continue
    _fs=$(git diff "${FROM_SHA}..${TO_SHA}" -- "$_f" 2>/dev/null | wc -c | tr -d ' ')
    total_diff_size=$(( total_diff_size + ${_fs:-0} ))
  done < ci_temp/changed_files.txt
fi
echo "Total diff size: ${total_diff_size} bytes (MAX_CHUNK_SIZE: ${MAX_CHUNK_SIZE})"

if [ "$file_count" -le "$REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING" ] && \
   [ "$total_diff_size" -le "$MAX_CHUNK_SIZE" ]; then
  FORCE_SINGLE_CHUNK=true
  echo "Using single chunk review (${file_count} files <= ${REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING} threshold, ${total_diff_size} bytes <= ${MAX_CHUNK_SIZE})"
  tr '\0' '\n' < ci_temp/changed_files.txt | awk 'NF {print "all-changes::" $0}' | sort > ci_temp/file_groups_sorted.txt
elif [ "$file_count" -le "$REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING" ]; then
  echo "File count is below the single-chunk threshold (${file_count} <= ${REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING}) but total diff size (${total_diff_size}) exceeds MAX_CHUNK_SIZE (${MAX_CHUNK_SIZE}); falling through to adaptive splitting to keep per-chunk prompts under the cap (regression from PR #86 CI review 4819995397)."
elif [ "$file_count" -ge "$SEMANTIC_GROUPING_THRESHOLD" ]; then
  echo "Attempting semantic business context grouping (${file_count} files >= ${SEMANTIC_GROUPING_THRESHOLD} threshold)..."

  # Build prompt for semantic grouping
  cat > ci_temp/semantic_grouping_prompt.txt << 'SEMANTIC_PROMPT_EOF'
You are a code review file grouper for a bunkering/shipping procurement application.

Given the list of changed files below, group them by business context for code review.
Files that belong to the same feature should be in the same group, even if they are in different directories.

RULES:
1. Each file must appear in exactly one group
2. Group files related to the same business feature together (e.g., backend handler + frontend component + tests for the same feature)
3. Keep test files with their related implementation files
4. Use short lowercase-hyphenated group names (e.g., "imos-integration", "claims-domain", "product-specs", "ef-config")
5. Aim for 3-8 groups total
6. If files don't clearly share a business context, group by technical layer
7. LOGIC MOVED pattern: If you see that one file has code REMOVED (e.g., validation logic deleted from a backend handler) and another file has similar code ADDED (e.g., same validation logic added to a frontend effect or different service), group BOTH files together. This ensures the reviewer can verify the move is correct and complete.

OUTPUT FORMAT (strictly one line per file, no markdown, no explanations, no blank lines):
group-name::filepath

EXAMPLE:
imos-integration::Bunkering.NetCore/Controllers/Bunkering/ImosController.cs
imos-integration::ProsmarTradeBlotterNetCore.Imos/Services/ImosOrderService.cs
imos-integration::Bunkering.NetCore.ComponentTests/Imos/ImosTests.cs
claims-domain::Bunkering.Application/Claim/BunkeringClaims/GetOrderDetailsHandler.cs
frontend-components::ProsmarBunkering.Web/src/app/controls/star-rating/star-rating.component.ts

FILES TO GROUP:
SEMANTIC_PROMPT_EOF

  # Append file list
  tr '\0' '\n' < ci_temp/changed_files.txt >> ci_temp/semantic_grouping_prompt.txt

  # Call the model for semantic grouping (60s timeout, no file access needed)
  # LADR-022: semantic grouping is file classification, not code analysis — use the
  # ORCHESTRATOR (cheap) model, falling back to the resolved review model if it's down.
  # LADR-023: CLI transport is opencode; helper preserves the fallback chain.
  if timeout 60s bash "$(dirname "${BASH_SOURCE[0]}")/lib/opencode-with-fallback.sh" "${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-gemini-3-flash-preview}" "$OPENCODE_MODEL_ID" "" -- ci_temp/semantic_grouping_prompt.txt > ci_temp/semantic_grouping_raw.txt 2>/dev/null; then
    # Extract only valid group::file lines, strip whitespace and backticks
    grep '::' ci_temp/semantic_grouping_raw.txt \
      | sed 's/^[[:space:]`]*//;s/[[:space:]`]*$//' \
      | grep -E -v '^#|^$|^EXAMPLE|^FILES|^group-name' \
      > ci_temp/semantic_grouping_result.txt 2>/dev/null || true

    # Validate: every changed file must appear exactly once
    expected_count="$file_count"
    found_count=$(wc -l < ci_temp/semantic_grouping_result.txt | tr -d ' ')

    # Check that file paths in result match actual changed files
    validation_ok=true
    if [ "$found_count" -ne "$expected_count" ]; then
      validation_ok=false
      echo "  ⚠️ File count mismatch (expected ${expected_count}, got ${found_count})"
    else
      # Verify each result file exists in changed_files
      while IFS= read -r result_line; do
        result_file="${result_line#*::}"
        if ! tr '\0' '\n' < ci_temp/changed_files.txt | grep -qxF "$result_file"; then
          validation_ok=false
          echo "  ⚠️ Unknown file in result: ${result_file}"
          break
        fi
      done < ci_temp/semantic_grouping_result.txt

      # Verify no duplicate files (each file must appear exactly once)
      if [ "$validation_ok" = true ]; then
        dupes=$(awk -F'::' '{print $2}' ci_temp/semantic_grouping_result.txt | sort | uniq -d)
        if [ -n "$dupes" ]; then
          validation_ok=false
          echo "  ⚠️ Duplicate files in result: ${dupes}"
        fi
      fi
    fi

    if [ "$validation_ok" = true ]; then
      sort ci_temp/semantic_grouping_result.txt > ci_temp/file_groups_sorted.txt
      SEMANTIC_GROUPING_SUCCESS=true
      echo "  ✅ Semantic grouping successful (${found_count} files)"
      echo "  Groups:"
      awk -F'::' '{print $1}' ci_temp/file_groups_sorted.txt | uniq -c | sort -rn | while IFS= read -r line; do
        echo "    ${line}"
      done
    else
      echo "  ⚠️ Validation failed - falling back to directory grouping"
    fi
  else
    echo "  ⚠️ Gemini call failed (timeout or API error) - falling back to directory grouping"
  fi
else
  echo "Skipping semantic grouping (${file_count} files < ${SEMANTIC_GROUPING_THRESHOLD} threshold)"
fi

echo ""

# Second pass: Group files by top-level directory (fallback if semantic grouping failed)
if [ "$FORCE_SINGLE_CHUNK" = false ] && [ "$SEMANTIC_GROUPING_SUCCESS" = false ]; then
  echo "Using directory-based grouping..."
  tr '\0' '\n' < ci_temp/changed_files.txt | while IFS= read -r file; do
    # Check if this is a test file with a mapped code file
    mapped_code_file=""
    while IFS= read -r mapping_line; do
      if [ "${mapping_line%%::*}" = "$file" ]; then
        mapped_code_file="${mapping_line#*::}"
        break
      fi
    done < ci_temp/file_mapping.txt

    if [ -n "$mapped_code_file" ]; then
      # Use the code file's directory for grouping test files
      full_dir=$(dirname "$mapped_code_file")
    else
      # Use the file's own directory
      full_dir=$(dirname "$file")
    fi

    # Extract top-level directory (1st level) for consolidation
    top_level_dir=$(echo "$full_dir" | cut -d'/' -f1)

    echo "${top_level_dir}::${file}"
  done | sort > ci_temp/file_groups_sorted.txt
fi

# --- Adaptive Chunk Splitting ---
# Splits oversized directory groups by progressively deeper directory levels
# to keep each chunk's diff within size limits for reliable Gemini processing
# LADR-035: hard chunk-prompt size enforcement. The adaptive split alone cannot
# bound the prompt (a single-directory group can't split deeper, and per-file
# diffs were appended unbounded — PR #5404 built a 90MB prompt and timed out).
MAX_FILE_DIFF_SIZE=$MAX_CHUNK_SIZE  # per-file diff cap inside a chunk prompt
MAX_PROMPT_DIFF_SIZE=204800         # 200KB total diff budget per chunk prompt

_process_chunk_group() {
  local group="$1"
  local files="$2"
  local count="$3"

  [ "$count" -eq 0 ] && return

  # Calculate cumulative diff size for this group
  local diff_size=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local fsize
    fsize=$(git diff "${FROM_SHA}..${TO_SHA}" -- "$f" 2>/dev/null | wc -c | tr -d ' ')
    diff_size=$((diff_size + ${fsize:-0}))
  done <<< "$files"

  if [ "$diff_size" -gt "$MAX_CHUNK_SIZE" ] && [ "$count" -gt 1 ]; then
    _had_splits=true
    local depth
    depth=$(echo "$group" | awk -F'/' '{print NF}')
    local new_depth=$((depth + 1))
    # Propose the deeper-directory regroup first, then check it actually splits.
    local proposed
    proposed=$(while IFS= read -r f; do
      [ -z "$f" ] && continue
      echo "$(dirname "$f" | cut -d'/' -f1-${new_depth})::${f}"
    done <<< "$files")
    local distinct_groups
    distinct_groups=$(printf '%s\n' "$proposed" | awk -F'::' '{print $1}' | sort -u | grep -c . || true)
    if [ "${distinct_groups:-0}" -le 1 ]; then
      # LADR-035: every file sits in the same directory (or the same single
      # deeper directory / semantic group), so the deeper-level regroup is a
      # no-op — the 5-iteration loop would exhaust and the oversized group
      # survive intact (PR #5404: 17 files in ONE directory → 90MB prompt →
      # 300s timeout). Halve the file list instead; an oversized half halves
      # again on the next iteration (up to 2^5 subgroups). '@' is safe in
      # group names — downstream parsing splits on '::' only.
      echo "  ⚡ Splitting '${group}' (${diff_size} bytes, ${count} files) → halving (single directory, cannot split deeper)" >&2
      local half=$(((count + 1) / 2))
      local idx=0
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        idx=$((idx + 1))
        if [ "$idx" -le "$half" ]; then
          echo "${group}@1::${f}"
        else
          echo "${group}@2::${f}"
        fi
      done <<< "$files"
    else
      echo "  ⚡ Splitting '${group}' (${diff_size} bytes, ${count} files) → deeper directory level" >&2
      printf '%s\n' "$proposed"
    fi
  else
    if [ "$diff_size" -gt "$MAX_CHUNK_SIZE" ]; then
      echo "  ⚠️ Single file in '${group}' exceeds limit (${diff_size} bytes) - cannot split further" >&2
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      echo "${group}::${f}"
    done <<< "$files"
  fi
}

if [ "$FORCE_SINGLE_CHUNK" = true ]; then
  echo "Skipping adaptive chunk splitting (single-chunk mode enabled)"
  echo ""
else
  echo ""
  echo "Adaptive chunk splitting (max diff size per chunk: ${MAX_CHUNK_SIZE} bytes)..."

  for _split_iter in 1 2 3 4 5; do
    _had_splits=false
    > ci_temp/file_groups_next.txt

    _current_group=""
    _current_files=""
    _current_count=0

    while IFS= read -r _line; do
      _group="${_line%%::*}"
      _file="${_line#*::}"

      if [ "$_group" != "$_current_group" ] && [ -n "$_current_group" ]; then
        _process_chunk_group "$_current_group" "$_current_files" "$_current_count" >> ci_temp/file_groups_next.txt
        _current_files=""
        _current_count=0
      fi

      _current_group="$_group"
      if [ -n "$_current_files" ]; then
        _current_files="${_current_files}
${_file}"
      else
        _current_files="$_file"
      fi
      _current_count=$((_current_count + 1))
    done < ci_temp/file_groups_sorted.txt

    # Process last group
    if [ "$_current_count" -gt 0 ]; then
      _process_chunk_group "$_current_group" "$_current_files" "$_current_count" >> ci_temp/file_groups_next.txt
    fi

    sort ci_temp/file_groups_next.txt > ci_temp/file_groups_sorted.txt

    if [ "$_had_splits" = false ]; then
      echo "  ✅ All chunks within size limit (${_split_iter} iteration(s))"
      break
    fi
  done

  echo ""
fi

# Process each directory group as a chunk
CHUNK_NUM=0
CURRENT_DIR=""
declare -a CURRENT_FILES

review_chunk() {
  local chunk_dir="$1"
  shift
  local files=("$@")
  local chunk_num="$CHUNK_NUM"

  echo "==========================================
"
  echo "Chunk #${chunk_num}: ${chunk_dir}"
  echo "Files: ${#files[@]}"
  echo "=========================================="

  # Build per-chunk context from global context_files.txt (produced by find-context-files.sh)
  > ci_temp/chunk_${chunk_num}_context.txt
  if [ -f ci_temp/context_files.txt ]; then
    while IFS= read -r ctx_file; do
      ctx_dir=$(dirname "$ctx_file")
      include=false

      # Always include root-level and dot-prefixed paths (mandatory/NFR context)
      if [ "$ctx_dir" = "." ] || [[ "$ctx_dir" == .* ]]; then
        include=true
      else
        # Include if context file's directory is an ancestor of any chunk file
        for f in "${files[@]}"; do
          if [[ "$f" == "${ctx_dir}/"* ]]; then
            include=true
            break
          fi
        done
      fi

      if [ "$include" = true ]; then
        echo "$ctx_file"
      fi
    done < ci_temp/context_files.txt >> ci_temp/chunk_${chunk_num}_context.txt

    # Remove duplicates
    if [ -s ci_temp/chunk_${chunk_num}_context.txt ]; then
      sort -u ci_temp/chunk_${chunk_num}_context.txt > ci_temp/chunk_${chunk_num}_context_unique.txt
      mv ci_temp/chunk_${chunk_num}_context_unique.txt ci_temp/chunk_${chunk_num}_context.txt
    fi
  fi

  # Build chunk prompt
  cat > ci_temp/chunk_${chunk_num}_prompt.txt << EOF
${EXPERTISE_STATEMENT}

You are reviewing a specific chunk of the pull request.

## 📁 CHUNK #${chunk_num}: ${chunk_dir}

**Files in this chunk:**
EOF

  for f in "${files[@]}"; do
    echo "- \`$f\`" >> ci_temp/chunk_${chunk_num}_prompt.txt
  done

  # Add AI Review Notes from PR author if available
  if [ -n "$AI_REVIEW_NOTES" ]; then
    cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

## 📝 AI REVIEW NOTES (from PR author)

The PR author has provided the following guidance for this review:

${AI_REVIEW_NOTES}

**Important:** Consider these notes when reviewing the code below.
- Any items listed under **"Skip Areas"** MUST be treated as out-of-scope for 🔴 Critical, 🟠 High, and 🟡 Medium classifications. If you observe a concern in a skip area, flag it as 🔵 Low Priority at most.

EOF
  fi

  # Add context file paths for on-demand reading (Implementation #89)
  if [ -s ci_temp/chunk_${chunk_num}_context.txt ]; then
    local context_count=$(wc -l < ci_temp/chunk_${chunk_num}_context.txt | tr -d ' ')
    echo "  📋 Context files for this chunk (${context_count}):"
    while IFS= read -r ctx_file; do
      echo "     - ${ctx_file}"
    done < ci_temp/chunk_${chunk_num}_context.txt

    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "## 🚨 MANDATORY: READ PROJECT CONTEXT FILES FIRST" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "**⚠️ CRITICAL REQUIREMENT: You MUST read these context files BEFORE reviewing any code.**" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "These files contain project-specific coding standards, language version information, and guidelines." >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "**Failure to read these files will result in false positives** (e.g., flagging valid C# 14 syntax as errors)." >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "**Context files to read (${context_count}):**" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt

    local ctx_num=1
    while IFS= read -r context_file; do
      echo "${ctx_num}. \`${context_file}\` - **READ THIS FILE NOW** using \`read_file\`" >> ci_temp/chunk_${chunk_num}_prompt.txt
      ctx_num=$((ctx_num + 1))
    done < ci_temp/chunk_${chunk_num}_context.txt

    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "**MANDATORY STEPS:**" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "1. Use \`read_file\` to load EACH context file listed above" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "2. Pay special attention to language version sections (e.g., C# 14, .NET 9)" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "3. Note any \"AI Code Review Note\" sections - these warn about valid syntax that AI may misidentify" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "4. Only AFTER reading context files, proceed to review the diff below" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "**⚠️ CRITICAL: CONTEXT FILES OVERRIDE YOUR TRAINING DATA**" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "This project uses **C# 14** with .NET 10 SDK. Your training data may not recognize C# 14 syntax." >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "If you see syntax like \`extension(Type target) { ... }\` or the \`field\` keyword - these are VALID C# 14 features." >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "**DO NOT flag these as syntax errors.** Trust the context files over your training data." >> ci_temp/chunk_${chunk_num}_prompt.txt
    echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
  else
    echo "  📋 No context files found for this chunk"
  fi

  # Testing rules are discovered via standard *AGENTS.md pattern (Implementation #89)
  # Testing_Rules_AGENTS.md will be in context_files if test directory is in changed paths

  # Get absolute path for file access instructions
  local repo_root="${GITHUB_WORKSPACE:-$(pwd)}"

  # Detect migration/schema chunks (SQL files or EF Core migration files)
  local is_migration=false
  for f in "${files[@]}"; do
    case "$f" in
      *.sql|*_Migration.cs|*/Migrations/*.cs) is_migration=true; break ;;
    esac
  done

  # Detect documentation-only chunks (all files are *.md, *.yml, *.yaml, *.json config)
  local is_doc_only=true
  for f in "${files[@]}"; do
    case "$f" in
      *AGENTS.md|*.instructions.md|*.instructions.mdc|*CLAUDE.md|*.yml|*.yaml) ;;
      *.md) ;;
      *) is_doc_only=false; break ;;
    esac
  done

  if [ "${REVIEW_MODE:-standard}" = "sync" ]; then
    echo "  🔄 Release branch sync — using sync review focus"
    cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

## 🔍 REVIEW INSTRUCTIONS (RELEASE BRANCH SYNC)

This is a release branch sync PR. All code changes were previously reviewed in their original PRs. Focus ONLY on issues introduced by the merge/sync process itself.

**Focus on (in priority order):**
1. **Merge conflict resolution errors** — Corrupted code, duplicated blocks, lost changes, or mangled syntax from incorrect conflict resolution.
2. **Cross-PR breaking combinations** — Changes from separate PRs that are individually correct but incompatible when combined (e.g., removed method still called by another PR's code, conflicting DB migrations).
3. **Configuration/environment drift** — appsettings, feature flags, or env vars that were overridden or lost during the sync.
4. **Migration ordering conflicts** — EF migrations with conflicting model snapshots or overlapping migration IDs.

**Explicitly DO NOT flag:**
- Coding style, naming conventions, or clean code issues
- Test coverage gaps
- Performance suggestions
- Documentation drift
- Refactoring opportunities
- Any issue that would have been caught in the original PR review

**Severity threshold:** Only use 🔴 Critical and 🟠 High. Classify anything below that as 🔵 Low (informational only). Do NOT use 🟡 Medium for sync reviews.
EOF
  elif [ "$is_migration" = true ]; then
    echo "  🗄️ Migration/schema chunk detected — using migration review focus"
    cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

## 🔍 REVIEW INSTRUCTIONS (MIGRATION/SCHEMA CHUNK)

This chunk contains database migration or schema files. Apply a migration-focused review instead of standard code review priorities.

**Focus on (in priority order):**

1. **Reversibility** — Is there a corresponding \`Down()\` method (EF) or rollback script? Can this migration be safely rolled back in production without data loss? If irreversible (e.g., column drop, data transformation), flag as High Priority.
2. **Existing data handling** — Does the migration account for existing rows? New \`NOT NULL\` columns without defaults will fail on non-empty tables. Data transformations must handle NULL and edge-case values.
3. **Nullable column safety** — New columns should be nullable or have a sensible \`DEFAULT\` unless the table is known to be empty. Changing nullable to non-nullable requires a data migration step first.
4. **Index impact** — Are new indexes added on large tables? Adding indexes without \`WITH (ONLINE = ON)\` (SQL Server) locks the table. Check if existing queries benefit from or are hurt by the new schema.
5. **Forward/backward compatibility** — Is the schema change backward compatible with the currently deployed application? The application may run with old code against the new schema during rolling deployment.
6. **Rollback strategy** — For destructive changes (\`DROP COLUMN\`, \`ALTER TYPE\`), document the rollback path. Can the application tolerate the old schema while the migration runs?

**Signal-to-noise guidelines:**
- **Reserve 🔴 Critical** for migrations that will corrupt data or cause downtime on deploy (e.g., DROP of a column still read by active code, NOT NULL without default on non-empty table).
- **Use 🟠 High** for migrations that lack a rollback path or have risky existing-data handling.
- **Use 🟡 Medium** for missing indexes, style issues, or suboptimal but safe choices.
- **Do NOT flag**: EF migration boilerplate, auto-generated designer code, timestamp-prefixed file naming.
EOF
  elif [ "$is_doc_only" = true ]; then
    echo "  📝 Documentation-only chunk detected — using documentation review focus"
    cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

## 🔍 REVIEW INSTRUCTIONS (DOCUMENTATION CHUNK)

This chunk contains only documentation files. Apply a documentation-focused review instead of code review priorities.

**Focus on (in priority order):**

1. **Factual accuracy** — Do descriptions, diagrams, and referenced file paths match the actual codebase? Are changelog entries accurate?
2. **Template compliance** — Does the file follow the project's AGENTS.md template structure? Note: all sections except Changelog are optional — omitted sections mean they don't apply. Do NOT flag missing sections as issues.
3. **Documentation drift** — If any documentation file in this chunk (README, AGENTS.md, HLDs, ADRs, LADRs, NFRs) describes code behavior, verify the described behavior matches the current implementation. Cap drift findings at 🟡 Medium — never 🟠 High or 🔴 Critical (LADR-046).
4. **Consistency** — Are naming conventions, formatting, and cross-references consistent with sibling files?
5. **Clarity** — Is the documentation clear and actionable for its intended AI agent audience?

**AGENTS.md Quality Standards** (from \`.agents/skills/ai-review-report/references/knowledge-conventional-contexts-quality.instructions.md\`):

When reviewing \`*_AGENTS.md\` files, check for these **anti-patterns**:
- **\`(src: path)\` annotations** — Remove; AI agents find files via glob/grep
- **File listings as "components"** — Remove; AI agents can discover files
- **Restating source code** — Remove; if visible from types/interfaces, it doesn't belong
- **Empty sections with "N/A"/"None"** — Omit the section entirely
- **Generic boilerplate** — Remove lines that add no AI coding value (e.g., "Required secrets: AWS_ACCESS_KEY_ID")
- **Business value / problem-solution-impact blocks** — Remove; these are for humans, not AI coders

Apply the **value test** — every line must pass at least ONE:
1. **Bug prevention**: Would an AI coder write worse code or introduce a bug without this?
2. **Decision quality**: Would an AI coder make a worse design choice without this?
3. **System understanding**: Does this reveal boundaries, constraints, or integrations not apparent from code?

**Diagram inclusion criteria** (flag if missing when criteria are met):
- **C4Context**: Required for services/workers with external integrations (APIs, DBs, queues). Omit for simple internal components.
- **Sequence diagram**: Required for handlers/workflows with 3+ steps OR side effects (emails, SignalR, external calls). Omit for simple CRUD.
- **ER diagram**: Required for DbContext/repositories operating on 3+ related entities with non-obvious relationships.

**Signal-to-noise guidelines:**
- **Documentation PRs have inherently lower risk.** Reserve 🔴 Critical and 🟠 High for factual inaccuracies that would cause AI agents to write incorrect code. Use 🔵 Low Priority for style and formatting concerns.
- **Documentation drift is capped at 🟡 Medium** — stale-context findings in any documentation file (AGENTS.md, README, HLDs, ADRs, LADRs, NFRs) that no longer matches the codebase must not be flagged 🟠 High or 🔴 Critical regardless of scope (LADR-046).
- **Do NOT flag missing optional template sections** (System Context, Quality Constraints, Migration Plans) — omission is intentional per project standards.
EOF
  else
    cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

## 🔍 REVIEW INSTRUCTIONS

Review ONLY the files listed above in this chunk. Apply any guidelines from the context documents.

**Focus on (in priority order):**

1. **Correctness and logic** — Bugs, off-by-one errors, null/undefined dereferences, unhandled edge cases (empty collections, null inputs, boundary values), and incorrect control flow. Ask: "What happens when this input is null, empty, zero, or at its boundary?"
2. **Concurrency and thread safety** — DbContext thread safety (no \`Task.WhenAll\` on shared DbContext — DR-008), shared mutable state accessed from multiple threads, race conditions in async code, missing locks on concurrent access. Elevated because thread-safety bugs often have no obvious symptoms until production load.
3. **Security vulnerabilities** — Injection flaws (SQL, command, XSS), authentication/authorization gaps, secrets exposure, insecure deserialization, missing input validation at system boundaries.
4. **API contract breaking changes** — Removed or renamed public fields, changed response shapes, modified endpoint signatures or return types that could break existing consumers. Especially relevant where frontend and backend evolve in the same PR.
5. **Error handling and resilience** — Missing try/catch where external calls can fail, swallowed exceptions, missing validation at API boundaries, failure modes that could cascade.
6. **Performance** — N+1 queries, unnecessary allocations in hot paths, missing async/await, blocking calls on async contexts, inefficient LINQ/collection operations.
7. **Test coverage** — If test files are in this chunk, verify they meaningfully cover the code changes. Flag missing test cases for new branches, edge cases, or error paths. If no test files are present for significant logic changes, note this as a gap.
8. **Readability and maintainability** — Is the code clear and self-documenting? Are names descriptive? Is complexity justified? Does it follow established patterns from the context documents?
9. **Clean Code principles** — Apply the checklist from \`.agents/rules/clean-code-principles.instructions.md\`: meaningful naming (no abbreviations, no misleading types), single-responsibility functions at one abstraction level, no Law of Demeter violations, no hidden side effects, no needless complexity or repetition. Defer to project-specific rules when they conflict.
10. **Project-specific standards** — Apply coding standards, patterns, and conventions from the loaded context documents. Context files override general best practices.
11. **Cross-file consistency** — For files in the same chunk, verify cross-file consistency: model fields reflected in mappers and DTOs, new actions have reducer cases, new interfaces have DI registrations, changed method signatures match all callers in the chunk.
EOF
  fi

  cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

**Signal-to-noise guidelines:**
- **Be precise, not pedantic.** Every issue should matter to a senior developer. Do not flag minor style preferences, subjective naming choices, or trivial formatting. 3 actionable findings > 15 nitpicks.
- **When intent is ambiguous**, note it as 🔵 Low Priority with question framing (e.g., "Intentional? If X happens, Y could be null") rather than flagging as a definitive bug.
- **Passing checks are not issues.** If you verify that a contract, convention, file shape, permission, diagram, or cross-file relationship is correct, mention it under positive highlights only if useful, or omit it. Do NOT list "No issue", "consistent", "verified", or "flagging only because checked" items under **Issues Found**, and do NOT assign them a severity.
- **Documentation drift is capped at 🟡 Medium** — when a PR modifies behavior described in any documentation file (AGENTS.md, README, HLDs, ADRs, LADRs, NFRs) but does NOT update that file, flag the stale documentation at Medium at most; never 🟠 High or 🔴 Critical (LADR-046).

**Verification-Incomplete Suppression:**
- If you did NOT receive a file in your review chunk (i.e., it is not listed in "Files in this chunk" above and its diff is not included below), do NOT flag test coverage, implementation concerns, or integration issues for that file at 🔴 Critical, 🟠 High, or 🟡 Medium priority. You may state that the file was not reviewed, but classify such observations at 🔵 Low Priority (informational) only.

**Confidence Tagging (MANDATORY):**
- Tag EVERY finding with exactly one of these labels:
  - **[VERIFIED]** — You saw the relevant source code in this chunk's diff OR you read the file using \`read_file\` to confirm the issue exists.
  - **[SPECULATIVE]** — You are inferring from partial context (e.g., a file was mentioned but not included in this chunk, or you are guessing about behavior you have not verified).
- Place the tag immediately after the priority emoji (e.g., "🟠 [VERIFIED] High Priority: ..." or "🔵 [SPECULATIVE] Low Priority: ...").
- **Platform-behavior claims:** if a finding depends on a claim about how an external platform or framework behaves (GitHub Actions contexts/triggers, npm/registry, git, SDK contracts) — not just on the code in the diff — that claim must itself be verified: confirmed from a context file, this repo's docs, or official documentation via \`webfetch\`. Seeing the code in the diff does NOT verify the platform claim. If you do not verify the claim, tag the finding [SPECULATIVE] — never [VERIFIED].
EOF

  # LADR-055: confidence anchors + quote-the-line gate. Quoted heredoc — this
  # block is full of backticks and JSON braces, and none of it may expand.
  if structured_findings_enabled; then
  cat >> ci_temp/chunk_${chunk_num}_prompt.txt << 'EOF'

**Confidence Anchors (MANDATORY, in addition to the tag above):**

Give every finding a `confidence` anchor — one of exactly `0`, `25`, `50`, `75`, `100`. Discrete anchors only: `72`, `0.85` and `"high"` are all invalid. Pick the single anchor whose behavioural criterion you can honestly self-apply. The rubric is anchored on behaviour you actually performed, not on a vague sense of certainty — if you cannot truthfully attach the behavioural claim to the finding, step down to the next anchor.

- **`0` — Not confident at all.** A false positive that does not stand up to light scrutiny, or a pre-existing issue this PR did not introduce. **Never emit.**
- **`25` — Somewhat confident.** Might be a real issue but could also be a false positive; you could not verify from the diff and surrounding code alone. **Never emit** — either gather more evidence (`read_file` the related files, resolve call sites with `grep`) until you can honestly anchor at `50` or higher, or suppress entirely.
- **`50` — Moderately confident.** You verified this is a real issue but it is a nitpick, narrow edge case, or has minimal practical impact. Style preferences and subjective improvements land here.
- **`75` — Highly confident.** You double-checked the diff and surrounding code and confirmed the issue will affect users, downstream callers, or runtime behavior in normal usage. The bug, vulnerability, or contract violation is clearly present and actionable. Anchor `75` requires **naming a concrete observable consequence** — a wrong result, an unhandled error path, a contract mismatch, a security exposure, missing coverage a real test scenario would surface. "This could be cleaner" or "I would have written this differently" do not meet this bar; they are anchor `50`. When torn between `50` and `75`, ask: **"will a user, caller, or operator concretely encounter this in normal usage, or is this my opinion about the code's quality?"** The former is `75`; the latter is `50`.
- **`100` — Absolutely certain.** The issue is verifiable from the code itself — compile error, type mismatch, definitive logic bug (off-by-one in a tested algorithm, wrong return type, swapped arguments), or an explicit project-standards violation with a quotable rule. No interpretation required.

**Anchor and severity are independent axes.** A 🟡 Medium finding can be anchor `100` if the evidence is airtight; a 🔴 Critical finding can be anchor `50` if it is an important concern you could not fully verify. The anchor gates *where* the finding surfaces; the severity orders it *within* the surfaced set. Do not raise an anchor to make a finding look important, and do not lower a severity because your anchor is low.

**Relationship to the tag above:** `[SPECULATIVE]` implies `confidence` of `50` or less — you cannot be highly confident in something you did not verify. `[VERIFIED]` means you read the code; the anchor then says how much it matters and how airtight the evidence is. A `[VERIFIED]` nitpick is anchor `50`, and that is the correct, expected outcome — it is not a failure to have verified something small.

**Quote-the-line gate (MANDATORY for anchors `75` and `100`):**

Before you anchor a finding at `75` or `100`, quote the verbatim line(s) that make it true, with `file:line`, as the **first** evidence item:

- "field X doesn't exist on model Y" → quote the class / `Meta` / migration where X would be defined.
- "`dict.get()` may return None" → quote the dict's initialization.
- "race between A and B" → quote both A and B.
- "swapped argument / wrong return" → quote the call site **and** the signature.

**If you cannot quote the motivating line, you cannot claim `75`+ — step down to `50`.** This is enforced mechanically after the review, not on trust: a finding at `75` or `100` with no quoted first evidence is demoted to `50` automatically, and the demotion is counted in the posted report.

**Framework carve-out — read this before flagging a "missing" symbol.** When the symbol is generated by a framework metaclass, ORM configuration, decorator, source generator, or migration history (EF Core fluent configuration / `DbSet` / migration snapshots, Rails `has_many`/`scope`, Django `Meta`, SQLAlchemy `Column`/`relationship`, Prisma client, TypeORM/Sequelize decorators), quote the **generating construct** — reading the source that generates the symbol satisfies the gate. **A failed `grep` for the literal name does NOT satisfy the gate and is not evidence that the symbol is absent.** This is the same rule as DR-012 (EF Core expression trees are translated to SQL, not executed as runtime C#) seen from the evidence side: in both cases the code that decides the behaviour is not the code the literal name appears in.
EOF
  fi

  cat >> ci_temp/chunk_${chunk_num}_prompt.txt << EOF

## ⚠️ CRITICAL: REVIEW SCOPE AND FILE ACCESS

**REVIEW SCOPE - DIFF ONLY:**
Your job is to review the CHANGES shown in the diff below. Do NOT review the entire file.
- 🎯 **Primary focus**: Lines that are ADDED or MODIFIED in the diff
- ❌ **Out of scope**: Existing code that was not changed (even if you can read it)

**FILE ACCESS - FOR CONTEXT VERIFICATION ONLY:**
You have file system access via the read_file tool. Use it ONLY to verify context, NOT to find new issues.

**FILE PATHS FOR read_file:**
- **Repository root (absolute):** \`${repo_root}\`
- **Use relative paths** from the diff (e.g., \`Bunkering.NetCore/Controllers/FooController.cs\`)
- **Or absolute paths** by prepending the repo root (e.g., \`${repo_root}/Bunkering.NetCore/Controllers/FooController.cs\`)
- The paths shown in the diff header \`diff --git a/path/to/file b/path/to/file\` are relative to the repo root
EOF

  cat >> ci_temp/chunk_${chunk_num}_prompt.txt << 'EOF'

**When to read files:**
- You see `IDisposable` in diff → READ the file to check if `Dispose()` method already exists
- You see a new class/method → READ the file to understand if related implementations exist
- You're unsure if something is handled elsewhere → READ the file to verify before flagging
- You want to flag a Critical or High Priority issue → ALWAYS read the file first to confirm

**MANDATORY WORKFLOW for Critical/High issues:**
1. Identify potential issue in the DIFF
2. **Read the CURRENT file state** using `read_file` to verify the issue exists in the actual code (not just in the diff hunk). The diff may show partial context — the issue may have been fixed in an earlier commit on the same branch.
3. **Confirm the flagged symbol/pattern exists** in the current file. If `read_file` shows the symbol is absent, DO NOT flag it — the diff is showing a removal or the change was already applied.
4. **If the issue rests on platform behavior** (e.g. "this expression is empty in context X", "this trigger never fires"), verify that behavior via `webfetch` of official docs before flagging Critical/High — or downgrade to [SPECULATIVE]. Known traps that are NOT issues:
   - In a workflow with `on.workflow_call`, the `github` context (`event_name`, `event.pull_request.*`) is the CALLER's. `github.event_name` is never "workflow_call"; a job `if:` gate listing the caller's event names and `github.event.pull_request.*` references are valid in reusable workflows.
   - GitHub Actions `branches:`/`tags:`/`paths:` filters are glob patterns, NOT regex. Dots are literal; never suggest regex-escaping them.
5. Only flag if the issue is TRULY present after checking the current file state

**Issue Classification Rules:**
- 🔴🟠🟡 **Critical/High/Medium**: ONLY for issues in the CHANGED code (diff lines)
- 🔵 **Low Priority**: Use for recommendations about UNCHANGED code you noticed while checking context
  - Example: "While verifying context, noticed [existing issue] - consider addressing in future PR"
  - These are suggestions, not blockers

**What NOT to do:**
- ❌ Don't review the entire file for issues unrelated to the diff
- ❌ Don't flag existing code issues as Critical/High/Medium
- ❌ Don't use file access to expand the review scope beyond the diff

**Output Format:**
For each file, use this structure:

### 📄 File: `filename`

**Issues Found:**
- 🔴 [VERIFIED] Critical: [description] or "None found"
- 🟠 [VERIFIED] High Priority: [description] or "None found"
- 🟡 [VERIFIED] Medium Priority: [description] or "None found"
- 🔵 [VERIFIED|SPECULATIVE] Low Priority: [description] or "None found"

Only include real defects, risks, or actionable documentation/maintenance issues in **Issues Found**. Passing consistency checks belong outside this section or should be omitted.

**Suggested Fixes:**
```language
[corrected code if applicable]
```
EOF

  # LADR-055: the machine-readable sidecar instruction, gated with the anchors.
  if structured_findings_enabled; then
  cat >> ci_temp/chunk_${chunk_num}_prompt.txt << 'EOF'

**Structured findings sidecar (LADR-055) — emit AFTER all of the markdown above:**

Once the human-readable review above is complete, append **one** block in exactly this shape as the very last thing in your output. The markdown above is the review; this block is a machine-readable mirror of the same findings for deduplication across chunks. It is stripped out before the review is posted, so it never appears to a human reader.

<!-- FINDINGS_JSON_BEGIN -->
```json
{
  "chunk": 0,
  "findings": [
    {
      "title": "Order lookup trusts a user-supplied account id",
      "severity": "critical",
      "file": "src/Controllers/OrdersController.cs",
      "line": 42,
      "why_it_matters": "Any signed-in user can read another user's orders by changing the account id in the URL. The action loads the account and returns its orders without checking the caller owns it. ShipmentsController:38 already guards the same attack class with CurrentUser.Owns(account); matching that guard fixes this.",
      "confidence": 100,
      "verified": true,
      "evidence": [
        "src/Controllers/OrdersController.cs:42 -- var account = await _db.Accounts.FindAsync(accountId);",
        "src/Controllers/ShipmentsController.cs:38 -- if (!CurrentUser.Owns(account)) return Forbid();"
      ],
      "first_evidence": "src/Controllers/OrdersController.cs:42 -- var account = await _db.Accounts.FindAsync(accountId);",
      "pre_existing": false,
      "requires_verification": true,
      "autofix_class": "gated_auto",
      "owner": "downstream-resolver",
      "suggested_fix": "Add the CurrentUser.Owns(account) guard before the lookup, matching ShipmentsController.cs:38."
    }
  ],
  "residual_risks": [],
  "testing_gaps": []
}
```
<!-- FINDINGS_JSON_END -->

Rules for the sidecar — a violated rule silently drops the finding from deduplication, it does not fail your review:

- `chunk` is this chunk's number, shown in the `## 📁 CHUNK #N` heading at the top of this prompt.
- `severity` is one of `"critical"`, `"high"`, `"medium"`, `"low"` — lower-case words, never emoji and never P0/P1/P2/P3.
- `verified` is `true` for a `[VERIFIED]` finding and `false` for a `[SPECULATIVE]` one — it must agree with the tag you used in the markdown above.
- `confidence` is one of the five anchors. `evidence` is an ARRAY of strings with at least one element, even when there is only one quote. At anchors `75`/`100` the first element must be the quoted motivating line, repeated in `first_evidence`.
- `autofix_class` is one of `"gated_auto"`, `"manual"`, `"advisory"`; `owner` is one of `"downstream-resolver"`, `"human"`, `"release"`. Nothing acts on these yet — classify honestly, they are routing signal only. Default `owner` to `"downstream-resolver"` unless the item genuinely needs human judgment first or is release/rollout work.
- `suggested_fix`, `first_evidence` and `graph_evidence` are optional; every other field is required on every finding.
- Emit **one** finding object per distinct defect. Every finding you listed under **Issues Found** above belongs here, and nothing that is not a finding does: no "None found" placeholders, no passing checks, no coverage notes.
- If you found nothing, emit the block with `"findings": []`.
- The block is the LAST thing in your output. Do not wrap it in extra prose, do not emit it twice, and do not put it before the markdown review.
EOF
  fi

  cat >> ci_temp/chunk_${chunk_num}_prompt.txt << 'EOF'

## 📝 DIFF TO REVIEW

EOF

  # Generate diff for just these files, with integrity checking and hard size
  # enforcement (LADR-035): a per-file cap (MAX_FILE_DIFF_SIZE) and a chunk-wide
  # diff budget (MAX_PROMPT_DIFF_SIZE). Oversized diffs are truncated/omitted
  # with read_file guidance instead of appended unbounded — safe because the
  # review agent has read access (LADR-025/029) and Critical/High already
  # requires read_file verification (LADR-015); a bounded prompt degrades to
  # on-demand reading, never to a timeout + forced fail-closed block (PR #5404).
  local prompt_diff_total=0
  for f in "${files[@]}"; do
    local file_diff
    file_diff=$(git diff "${FROM_SHA}..${TO_SHA}" -- "$f" 2>/dev/null) || {
      echo "⚠️ Could not generate diff for: $f" >> ci_temp/chunk_${chunk_num}_prompt.txt
      continue
    }
    local file_diff_size
    file_diff_size=$(printf '%s' "$file_diff" | wc -c | tr -d ' ')

    # Budget exhausted: append NO diff for this file — read_file on demand only.
    if [ "$prompt_diff_total" -ge "$MAX_PROMPT_DIFF_SIZE" ]; then
      echo "  ✂️ Diff omitted for ${f} (${file_diff_size} bytes — chunk diff budget exhausted)"
      echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
      echo "⚠️ **DIFF OMITTED for \`$f\`** (${file_diff_size} bytes): the chunk prompt diff budget (${MAX_PROMPT_DIFF_SIZE} bytes) is exhausted. Use \`read_file\` to review this file. **Do NOT raise Critical or High issues for this file without \`read_file\` verification.**" >> ci_temp/chunk_${chunk_num}_prompt.txt
      echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
      continue
    fi

    # Per-file cap, never exceeding what is left of the chunk budget.
    local budget_left=$((MAX_PROMPT_DIFF_SIZE - prompt_diff_total))
    local effective_cap=$MAX_FILE_DIFF_SIZE
    if [ "$budget_left" -lt "$effective_cap" ]; then
      effective_cap=$budget_left
    fi

    if [ "$file_diff_size" -gt "$effective_cap" ]; then
      # LADR-015 integrity warning, reworded for LADR-035: the diff is now
      # actually truncated (not just "may be incomplete").
      local omitted_bytes=$((file_diff_size - effective_cap))
      echo "  ✂️ Diff truncated for ${f} (${file_diff_size} → ${effective_cap} bytes)"
      echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
      echo "⚠️ **DIFF INTEGRITY WARNING for \`$f\`**: This file's diff is very large (${file_diff_size} bytes) and has been TRUNCATED to the first ${effective_cap} bytes below. **Do NOT raise Critical or High issues for this file without first using \`read_file\` to verify the current file state.**" >> ci_temp/chunk_${chunk_num}_prompt.txt
      echo "" >> ci_temp/chunk_${chunk_num}_prompt.txt
      printf '%s' "$file_diff" | head -c "$effective_cap" >> ci_temp/chunk_${chunk_num}_prompt.txt
      printf '\n' >> ci_temp/chunk_${chunk_num}_prompt.txt
      echo "[... diff truncated: ${omitted_bytes} bytes omitted — use \`read_file\` to see the full file ...]" >> ci_temp/chunk_${chunk_num}_prompt.txt
      prompt_diff_total=$((prompt_diff_total + effective_cap))
    else
      echo "$file_diff" >> ci_temp/chunk_${chunk_num}_prompt.txt
      prompt_diff_total=$((prompt_diff_total + file_diff_size))
    fi
  done

  # Get prompt size
  local prompt_size=$(wc -c < ci_temp/chunk_${chunk_num}_prompt.txt | tr -d ' ')
  echo "  Prompt size: ${prompt_size} bytes"

  # Warn if prompt exceeds safe limits
  if [ "$prompt_size" -gt 250000 ]; then
    echo "  ⚠️ WARNING: Prompt size ${prompt_size} bytes may cause timeout"
  fi

  # Review with the agent model via opencode (LADR-023 transport)
  echo "  Reviewing with agent model (with file access enabled)..."
  # 5-minute timeout (300s) to prevent indefinite hangs.
  # opencode-with-fallback.sh runs the locked-down `review` agent (LADR-029,
  # --agent review; read/grep only, no skill/task/edit/bash) with the model
  # overridden via --model. That agent provides read/grep, so the prompt's
  # read_file context-loading works (with the diff also inline as a fallback),
  # but cannot self-activate this repo's ai-review-report skill. Fallback chain
  # preserves LADR-002.
  # Single source of truth for the budget — `lib/validate-chunk-timeout.sh` is
  # also what the test exercises, so the fallback-on-bad-value contract cannot
  # drift away from the code that enforces it.
  _chunk_timeout="$(bash "$(dirname "${BASH_SOURCE[0]}")/lib/validate-chunk-timeout.sh")"
  if timeout "${_chunk_timeout}s" bash "$(dirname "${BASH_SOURCE[0]}")/lib/opencode-with-fallback.sh" "$OPENCODE_MODEL_ID" "${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-gemini-2.5-pro}" "" -- ci_temp/chunk_${chunk_num}_prompt.txt > ci_temp/reviews/chunk_${chunk_num}.md 2>ci_temp/reviews/chunk_${chunk_num}_stderr.log; then
    # LADR-055: pull the structured-findings sidecar out and strip it from the
    # markdown. Runs BEFORE the empty-output floor below on purpose — the floor
    # must measure the markdown a human will actually read, so a model that
    # returned nothing but a JSON block still trips it. Best-effort and never a
    # chunk failure: this call cannot write a `.failed` flag (LADR-031 owns that
    # channel) and its exit code is deliberately ignored.
    if structured_findings_enabled; then
      bash "$(dirname "${BASH_SOURCE[0]}")/lib/extract-findings-json.sh" \
        "ci_temp/reviews/chunk_${chunk_num}.md" \
        "${chunk_num}" \
        "ci_temp/reviews/chunk_${chunk_num}.findings.json" || true
    fi

    # Empty-output detection: opencode can exit 0 while producing no review
    # text (e.g. provider silently failing, agent misconfiguration). A real
    # chunk review is always at least a few hundred bytes of markdown with
    # priority headings. Anything smaller is a no-op — surface stderr so we
    # can see what happened instead of silently aggregating an empty file.
    local review_size
    review_size=$(wc -c < "ci_temp/reviews/chunk_${chunk_num}.md" 2>/dev/null || echo 0)
    if [ "$review_size" -lt 200 ]; then
      echo "  ⚠️ Chunk ${chunk_num} returned empty/tiny output (${review_size} bytes) — opencode silent failure?"
      echo "  --- chunk_${chunk_num}.md content ---"
      cat "ci_temp/reviews/chunk_${chunk_num}.md" || true
      echo "  --- chunk_${chunk_num}_stderr.log ---"
      cat "ci_temp/reviews/chunk_${chunk_num}_stderr.log" 2>/dev/null || true
      echo "  ---"
      # Overwrite the empty chunk file with a visible failure marker so the
      # silent failure surfaces in the posted PR review body (not just CI
      # logs). Without this the aggregation step concatenates an empty file
      # and the chunk disappears from the review.
      {
        echo "## ⚠️ Review Failed for Chunk: ${chunk_dir}"
        echo ""
        echo "**Reason:** opencode returned empty/tiny output (${review_size} bytes) — provider failure or agent tool-misfire (e.g. skill self-activation; see LADR-029)."
        echo ""
        echo "Check the workflow logs for \`chunk_${chunk_num}_stderr.log\` contents."
      } > "ci_temp/reviews/chunk_${chunk_num}.md"
      # LADR-031: out-of-band failure signal. Aggregation keys its fail-closed
      # decision off this flag file, NOT off grepping the marker text above — the
      # marker string gets quoted into legitimate review bodies when the gate
      # reviews its own docs, which text-grepping false-matches (see LADR-031).
      echo "empty/tiny output (${review_size} bytes)" > "ci_temp/reviews/chunk_${chunk_num}.failed"
      # Exit 0 with no output is the quieter failure of the two — surface its
      # stderr too, or the run reports "empty" with no way to learn why.
      bash "$(dirname "${BASH_SOURCE[0]}")/lib/report-error-log.sh" \
        "chunk_${chunk_num}_${chunk_dir}_empty" \
        "ci_temp/reviews/chunk_${chunk_num}_stderr.log" || true
      # A failed chunk contributes no findings (LADR-055). Drop any sidecar the
      # extraction step managed to salvage, so the merged set and the failed-chunk
      # count can never disagree about which chunks were actually reviewed.
      rm -f "ci_temp/reviews/chunk_${chunk_num}.findings.json"
    else
      echo "  ✅ Chunk ${chunk_num} review completed (${review_size} bytes)"
    fi
  else
    local exit_code=$?
    echo "  ❌ Chunk ${chunk_num} review failed (exit code: ${exit_code})"
    # Preserve and PRINT the stderr. Naming the path was useless: the cleanup
    # step rm -rf's ci_temp on always(), so by the time anyone read the workflow
    # log the file it pointed at was gone (PR #106 run 30756015689 lost the only
    # evidence of why two chunks failed).
    bash "$(dirname "${BASH_SOURCE[0]}")/lib/report-error-log.sh" \
      "chunk_${chunk_num}_${chunk_dir}" \
      "ci_temp/reviews/chunk_${chunk_num}_stderr.log" || true
    {
      echo "## ⚠️ Review Failed for Chunk: ${chunk_dir}"
      echo ""
      echo "**Exit Code:** ${exit_code}"
      if [ "$exit_code" -eq 124 ]; then
        # The timeout wraps the whole fallback chain, so on 124 the secondary
        # model was never reached — say so rather than implying the chain was
        # tried and exhausted. Raise OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT to
        # give it room.
        echo "**Reason:** Timeout (>${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT}s). The budget wraps the whole model chain, so the fallback model was not reached — raise \`OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT\` if this recurs."
      elif [ "$exit_code" -eq 137 ]; then
        echo "**Reason:** Out of memory or killed"
      else
        echo "**Reason:** opencode / model API error (all fallbacks exhausted)"
      fi
      echo ""
      echo "**Chunk:** ${chunk_dir} (${#files[@]} files)"
      echo "**Prompt Size:** ${prompt_size} bytes"
    } > ci_temp/reviews/chunk_${chunk_num}.md
    # LADR-031: out-of-band failure signal (see comment at the empty/tiny site).
    echo "exit code ${exit_code}" > "ci_temp/reviews/chunk_${chunk_num}.failed"
    # LADR-055: a failed chunk contributes no findings — clear any stale sidecar.
    rm -f "ci_temp/reviews/chunk_${chunk_num}.findings.json"
  fi

  echo ""
}

# --- Parallel Chunk Processing ---
# Chunks are independent (no shared state) so they can run concurrently.
# MAX_PARALLEL caps concurrent Gemini API calls to avoid rate limiting.
MAX_PARALLEL=${MAX_PARALLEL:-10}

# Phase 1: Collect all chunk groups (prompts are built inside review_chunk)
declare -a CHUNK_DIRS
declare -a CHUNK_FILE_LISTS

while IFS='::' read -r dir file; do
  if [ "$dir" != "$CURRENT_DIR" ] && [ -n "$CURRENT_DIR" ]; then
    CHUNK_DIRS+=("$CURRENT_DIR")
    # Store files as newline-separated string for this chunk
    CHUNK_FILE_LISTS+=("$(printf '%s\n' "${CURRENT_FILES[@]}")")
    CHUNK_NUM=$((CHUNK_NUM + 1))
    CURRENT_FILES=()
  fi

  CURRENT_DIR="$dir"
  CURRENT_FILES+=("$file")
done < ci_temp/file_groups_sorted.txt

# Last group
if [ ${#CURRENT_FILES[@]} -gt 0 ]; then
  CHUNK_DIRS+=("$CURRENT_DIR")
  CHUNK_FILE_LISTS+=("$(printf '%s\n' "${CURRENT_FILES[@]}")")
  CHUNK_NUM=$((CHUNK_NUM + 1))
fi

TOTAL_CHUNKS=$CHUNK_NUM

echo "=========================================="
echo "Processing $TOTAL_CHUNKS chunks (max $MAX_PARALLEL parallel)"
echo "=========================================="
echo ""

# Phase 2: Launch chunk reviews in parallel with concurrency cap
declare -a CHUNK_PIDS
declare -a CHUNK_EXIT_CODES
RUNNING=0

# Reset CHUNK_NUM for review_chunk (it reads the global)
CHUNK_NUM=0

for i in $(seq 0 $((TOTAL_CHUNKS - 1))); do
  CHUNK_NUM=$i

  # Convert newline-separated file list back to array
  mapfile -t chunk_files <<< "${CHUNK_FILE_LISTS[$i]}"

  # Launch review_chunk in a subshell background process
  (
    review_chunk "${CHUNK_DIRS[$i]}" "${chunk_files[@]}"
  ) &
  CHUNK_PIDS[$i]=$!
  echo "  🚀 Launched chunk #${i} (${CHUNK_DIRS[$i]}) — PID ${CHUNK_PIDS[$i]}"

  RUNNING=$((RUNNING + 1))

  # Concurrency cap: wait for any one to finish before launching more
  if [ "$RUNNING" -ge "$MAX_PARALLEL" ]; then
    # Wait for any background job to complete
    wait -n 2>/dev/null || true
    RUNNING=$((RUNNING - 1))
  fi
done

# Wait for all remaining background jobs
echo ""
echo "Waiting for all chunks to complete..."
FAILED_CHUNKS=0
for i in $(seq 0 $((TOTAL_CHUNKS - 1))); do
  wait "${CHUNK_PIDS[$i]}" 2>/dev/null
  CHUNK_EXIT_CODES[$i]=$?
  if [ "${CHUNK_EXIT_CODES[$i]}" -ne 0 ]; then
    echo "  ⚠️ Chunk #${i} (${CHUNK_DIRS[$i]}) exited with code ${CHUNK_EXIT_CODES[$i]}"
    FAILED_CHUNKS=$((FAILED_CHUNKS + 1))
  fi
done

# Restore CHUNK_NUM to total for downstream output
CHUNK_NUM=$TOTAL_CHUNKS

echo ""
echo "=========================================="
echo "Chunked Review Complete"
echo "Total chunks: $TOTAL_CHUNKS"
if [ "$FAILED_CHUNKS" -gt 0 ]; then
  echo "Failed chunks: $FAILED_CHUNKS"
fi
echo "=========================================="

# Collect and deduplicate context files from all chunks (Implementation #90)
# Each chunk writes to ci_temp/chunk_N_context.txt — merge after parallel completion
> ci_temp/all_context_files.txt
for i in $(seq 0 $((TOTAL_CHUNKS - 1))); do
  if [ -f "ci_temp/chunk_${i}_context.txt" ]; then
    cat "ci_temp/chunk_${i}_context.txt" >> ci_temp/all_context_files.txt
  fi
done
if [ -s ci_temp/all_context_files.txt ]; then
  sort -u ci_temp/all_context_files.txt > ci_temp/all_context_files_unique.txt
  mv ci_temp/all_context_files_unique.txt ci_temp/all_context_files.txt
  echo ""
  echo "📚 Total unique context files across all chunks: $(wc -l < ci_temp/all_context_files.txt | tr -d ' ')"
fi

# Output for workflow
echo "total_chunks=$CHUNK_NUM" >> "$GITHUB_OUTPUT"
