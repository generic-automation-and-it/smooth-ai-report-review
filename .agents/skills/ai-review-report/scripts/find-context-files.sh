#!/bin/bash
set -e

# Script: find-context-files.sh
# Purpose: Discover custom *_AGENTS.md and .github instruction files. Standard
#          AGENTS.md files are loaded natively by opencode v2's scoped
#          discovery and must not be duplicated in chunk prompts.
# Usage: Called from pipeline-code-review-report.yml workflow
# Output: ci_temp/context_files.txt with list of relevant context files

echo "Looking for custom *_AGENTS.md and .github instruction files..."

# Check if we have changed files
if [ ! -f ci_temp/changed_files.txt ] || [ ! -s ci_temp/changed_files.txt ]; then
  echo "No changed files to analyze"
  echo "has_context=false" >> "$GITHUB_OUTPUT"
  echo "context_file_count=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Extract unique directory paths from changed files
tr '\0' '\n' < ci_temp/changed_files.txt | while IFS= read -r file; do
  dirname "$file"
done | sort -u > ci_temp/changed_dirs.txt

# Filter: keep custom *_AGENTS.md files in parent paths.
# Exact basename AGENTS.md is deliberately excluded: opencode v2 loads the
# root/ambient file initially and discovers nested files as it reads or lists
# their scope.
> ci_temp/relevant_agents_files.txt
while IFS= read -r changed_dir; do
  # For each changed directory, walk up to root checking for AGENT.md files
  current_dir="$changed_dir"
  while [ "$current_dir" != "." ] && [ -n "$current_dir" ]; do
    # The underscore is the repo's convention AND is load-bearing here.
    # `*AGENTS.md` would also match the exact standard basename — in find(1)
    # a leading `*` matches zero characters — and opencode v2 already loads
    # every `AGENTS.md` natively by scope, so matching it here would inject
    # the same file twice into the prompt. `*_AGENTS.md` expresses that
    # exclusion in the pattern itself rather than relying on a companion
    # `! -name "AGENTS.md"` carve-out that a later edit can drop without the
    # duplication being obvious.
    find "$current_dir" -maxdepth 1 -type f \
      -name "*_AGENTS.md" ! -name "TEMPLATE_*" \
      >> ci_temp/relevant_agents_files.txt 2>/dev/null || true
    # Move up one directory
    current_dir=$(dirname "$current_dir")
  done
done < ci_temp/changed_dirs.txt

# Feature-specific *_AGENTS.md files in root (e.g., CLAIMS_MIGRATION_TO_NEW_MODULE_AGENTS.md)
# should NOT be auto-included - they are only relevant when their feature area has changes

# opencode v2 accepts an `instructions` config array but currently resolves
# none of its files/globs/URLs. Every default the config declares must
# therefore be enumerated here too, or it is declared and never loaded — the
# LADR-087 false-OK shape. Keep the two lists in step: adding an entry to
# `assets/opencode.json`'s `instructions` without adding it here ships a rule
# file that silently never reaches the model.
#
# `find` recurses, so one traversal covers BOTH glob forms the config carries
# (`dir/*.md` and `dir/**/*.md`). The pair exists in the config because v1's
# glob engine treated them differently; it is not two different file sets.
#
# `.agents/rules-scoped/**` is deliberately NOT here. Scoped rules reach a
# review through `MANDATORY_CONTEXT_FILES`, which the consuming repo controls
# per-run; pulling the whole scoped tree into every chunk would duplicate them
# and inflate prompts for chunks the scope does not apply to.
#
# Both trees are consumer-repo paths and are absent from this repo, so each
# block is existence-guarded. Dot-prefixed context paths are included in every
# chunk by review-in-chunks.sh.
if [ -d .agents/rules ]; then
  find .agents/rules -type f -name '*.md' ! -name 'AGENTS.md' \
    >> ci_temp/relevant_agents_files.txt 2>/dev/null || true
fi
if [ -d .github/instructions ]; then
  find .github/instructions -type f -name '*.instructions.md' \
    >> ci_temp/relevant_agents_files.txt 2>/dev/null || true
fi

# Add mandatory context files (always loaded for all reviews)
# These are configured in the workflow via MANDATORY_CONTEXT_FILES env variable.
# The variable must be set; running without it drops all mandatory context and
# violates the fail-closed invariant from LADR-025/029.
# Mandatory paths are also recorded separately: the per-chunk scope filter
# (lib/filter-context-scope.sh) keeps them regardless of any `applyTo` they
# declare, because the consuming repo named them explicitly.
> ci_temp/mandatory_context_files.txt
echo "Adding mandatory context files..."
if [ -z "${MANDATORY_CONTEXT_FILES:-}" ]; then
  echo "  ❌ MANDATORY_CONTEXT_FILES env variable not set" >&2
  exit 2
fi

# `none`, as the whole value (any case), declares that the repo under review
# has no mandatory context files. It is an explicit opt-out, so the unset check
# above still fails closed: a blank value cannot mean "none", because every
# layer (the workflow's `||` chain, run-review.sh) turns blank into the
# built-in product-repo list — which is how a repo without those files ended up
# with five "not found" warnings on every run.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mandatory-context.sh"
if mandatory_context_is_none "$MANDATORY_CONTEXT_FILES"; then
  echo "  ℹ️ MANDATORY_CONTEXT_FILES=none — the repo declares no mandatory context files"
  MANDATORY_CONTEXT_FILES=""
fi

for ctx_file in $MANDATORY_CONTEXT_FILES; do
  if [ -f "$ctx_file" ]; then
    if [ "$(basename "$ctx_file")" = "AGENTS.md" ]; then
      echo "  - $ctx_file (native opencode v2 AGENTS.md scope; not duplicated)"
      continue
    fi
    echo "$ctx_file" >> ci_temp/relevant_agents_files.txt
    echo "$ctx_file" >> ci_temp/mandatory_context_files.txt
    echo "  - $ctx_file (mandatory)"
  else
    # Missing paths are warned, not fatal: the default list is intentionally
    # reusable across repos and resolves against the repo under review.
    echo "  ⚠ Warning: Mandatory context file not found: $ctx_file" >&2
  fi
done

# Remove duplicates and sort
if [ -s ci_temp/relevant_agents_files.txt ]; then
  sort -u ci_temp/relevant_agents_files.txt > ci_temp/context_files.txt
  CONTEXT_FILE_COUNT=$(wc -l < ci_temp/context_files.txt | tr -d ' ')

  echo ""
  echo "Found $CONTEXT_FILE_COUNT relevant context files:"
  cat ci_temp/context_files.txt

  # No size filtering - the model reads explicit custom/rule files on demand.
  # File paths are listed in the prompt; opencode.json sets
  # permission.external_directory: allow (LADR-025) so reads of in-repo dot-paths
  # succeed in headless run mode (the old gemini-cli used --yolo for this).
  echo ""
  echo "Context file paths will be provided to the model for on-demand reading"
  echo "has_context=true" >> "$GITHUB_OUTPUT"
  echo "context_file_count=$CONTEXT_FILE_COUNT" >> "$GITHUB_OUTPUT"
else
  echo "No relevant context files found"
  echo "has_context=false" >> "$GITHUB_OUTPUT"
  echo "context_file_count=0" >> "$GITHUB_OUTPUT"
fi
