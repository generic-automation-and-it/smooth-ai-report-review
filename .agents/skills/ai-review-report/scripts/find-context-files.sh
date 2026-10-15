#!/bin/bash
set -e

# Script: find-context-files.sh
# Purpose: Discover scoped instruction files and opt-in mandatory paths. Standard
#          AGENTS.md files are loaded natively by opencode v2's scoped
#          discovery and must not be duplicated in chunk prompts.
# Usage: Called from pipeline-code-review-report.yml workflow
# Output: ci_temp/context_files.txt with list of relevant context files

echo "Looking for .github/instructions/**/*.instructions.scoped.md files..."

# Check if we have changed files
if [ ! -f ci_temp/changed_files.txt ] || [ ! -s ci_temp/changed_files.txt ]; then
  echo "No changed files to analyze"
  echo "has_context=false" >> "$GITHUB_OUTPUT"
  echo "context_file_count=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Automatic custom loading is scoped-instructions-only (LADR-105). Standard
# AGENTS.md remains owned by native opencode v2 discovery. No ancestor
# *_AGENTS.md walk or blanket .agents/rules/*.md scan belongs in this channel.
: > ci_temp/relevant_agents_files.txt
# v2 still does not resolve the config's `instructions` array (LADR-087).
# Retain the existing scoped-file compatibility search without changing config
# globs or expanding discovery to new directories. find covers both root and
# nested files in .github/instructions. Scope is filtered per chunk before
# runtime AGENTS.md delivery; config's .agents/rules entries stay declarative.
if [ -d .github/instructions ]; then
  find .github/instructions -type f -name '*.instructions.scoped.md' \
    >> ci_temp/relevant_agents_files.txt 2>/dev/null || true
fi

# Add explicitly requested mandatory context files (none by default).
# These are configured in the workflow via MANDATORY_CONTEXT_FILES env variable.
# Unset/blank means none; no product-repo paths are assumed (LADR-105).
# Mandatory paths are also recorded separately: the per-chunk scope filter
# (lib/filter-context-scope.sh) keeps them regardless of any `applyTo` they
# declare, because the consuming repo named them explicitly.
: > ci_temp/mandatory_context_files.txt
MANDATORY_CONTEXT_FILES="${MANDATORY_CONTEXT_FILES:-none}"

# `none`, as the whole value (any case), declares that the repo under review
# has no mandatory context files. Explicit non-empty lists still opt in,
# regardless of filename. Only the whole value `none` opts out.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mandatory-context.sh"
if mandatory_context_is_none "$MANDATORY_CONTEXT_FILES"; then
  echo "  ℹ️ MANDATORY_CONTEXT_FILES=none — the repo declares no mandatory context files"
  MANDATORY_CONTEXT_FILES=""
else
  echo "Adding explicitly requested mandatory context files..."
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
    # Explicit paths resolve against the reviewed repo; missing ones warn.
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

  echo ""
  echo "Context files will be scope-filtered and loaded into runtime AGENTS.md instructions"
  echo "has_context=true" >> "$GITHUB_OUTPUT"
  echo "context_file_count=$CONTEXT_FILE_COUNT" >> "$GITHUB_OUTPUT"
else
  echo "No relevant context files found"
  echo "has_context=false" >> "$GITHUB_OUTPUT"
  echo "context_file_count=0" >> "$GITHUB_OUTPUT"
fi
