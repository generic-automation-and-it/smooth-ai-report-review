#!/bin/bash
set -eo pipefail

# Requires Bash >= 4 for consistent diagnostics with the sibling runtime
# scripts. GitHub-hosted runners satisfy this; macOS local runs should use a
# Homebrew bash via local-review.sh.
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "❌ Requires Bash >= 4 (found ${BASH_VERSION:-unknown}). On macOS: 'brew install bash'." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGED_FILES="ci_temp/changed_files.txt"
EXCLUDED_FILES="ci_temp/excluded_files.txt"

# Filters are intentionally opt-in. A review normally sees every changed file;
# callers enable a filter only when that class is known to be non-actionable.
EXCLUDE_GENERATED_PATHS="${OPENCODE_REVIEW_REPORT_EXCLUDE_GENERATED_PATHS:-}"
EXCLUDE_DELETED="${OPENCODE_REVIEW_REPORT_EXCLUDE_DELETED:-0}"
DIFF_FROM_SHA="${OPENCODE_REVIEW_REPORT_DIFF_FROM_SHA:-}"
DIFF_TO_SHA="${OPENCODE_REVIEW_REPORT_DIFF_TO_SHA:-}"

is_truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=========================================="
echo "Filtering excluded files from review"
echo "=========================================="

if [ ! -f "$CHANGED_FILES" ] || [ ! -s "$CHANGED_FILES" ]; then
  echo "No changed files to filter"
  exit 0
fi

declare -a GENERATED_PATHS=()
while IFS= read -r generated_path; do
  generated_path="${generated_path%/}"
  [ -n "$generated_path" ] && GENERATED_PATHS+=("$generated_path")
done <<< "$EXCLUDE_GENERATED_PATHS"

if [ "${#GENERATED_PATHS[@]}" -gt 0 ]; then
  echo "Generated paths excluded from review:"
  printf '  - %s\n' "${GENERATED_PATHS[@]}"
fi

declare -A DELETED_FILES=()
if is_truthy "$EXCLUDE_DELETED"; then
  if [ -z "$DIFF_FROM_SHA" ] || [ -z "$DIFF_TO_SHA" ]; then
    echo "❌ Deleted-file filter requires OPENCODE_REVIEW_REPORT_DIFF_FROM_SHA and _TO_SHA." >&2
    exit 1
  fi
  deleted_paths_file="$(mktemp)"
  if ! git diff --name-only -z --diff-filter=D "${DIFF_FROM_SHA}..${DIFF_TO_SHA}" > "$deleted_paths_file"; then
    rm -f "$deleted_paths_file"
    exit 1
  fi
  while IFS= read -r -d '' file; do
    DELETED_FILES["$file"]=1
  done < "$deleted_paths_file"
  rm -f "$deleted_paths_file"
fi

if [ "${#GENERATED_PATHS[@]}" -eq 0 ] && ! is_truthy "$EXCLUDE_DELETED"; then
  echo "No exclusion filters enabled"
  exit 0
fi

BEFORE_COUNT=$(bash "$SCRIPT_DIR/lib/count-changed-files.sh" "$CHANGED_FILES")

> "$EXCLUDED_FILES"
> ci_temp/changed_files_filtered.txt

tr '\0' '\n' < "$CHANGED_FILES" | while IFS= read -r file; do
  [ -z "$file" ] && continue
  exclude_reason=""

  if is_truthy "$EXCLUDE_DELETED" && [ -n "${DELETED_FILES[$file]:-}" ]; then
    exclude_reason="deleted"
  elif [ "${#GENERATED_PATHS[@]}" -gt 0 ]; then
    for generated_path in "${GENERATED_PATHS[@]}"; do
      case "$file" in
        "$generated_path"|"$generated_path"/*)
          exclude_reason="generated"
          break
          ;;
      esac
    done
  fi

  if [ -n "$exclude_reason" ]; then
    printf '%s\t%s\n' "$exclude_reason" "$file" >> "$EXCLUDED_FILES"
  else
    printf '%s\0' "$file" >> ci_temp/changed_files_filtered.txt
  fi
done

mv ci_temp/changed_files_filtered.txt "$CHANGED_FILES"

AFTER_COUNT=$(bash "$SCRIPT_DIR/lib/count-changed-files.sh" "$CHANGED_FILES")
EXCLUDED_COUNT=$((BEFORE_COUNT - AFTER_COUNT))

echo ""
echo "Results:"
echo "  Files before: $BEFORE_COUNT"
echo "  Files excluded: $EXCLUDED_COUNT"
echo "  Files remaining: $AFTER_COUNT"

if [ "$EXCLUDED_COUNT" -gt 0 ]; then
  echo ""
  echo "Excluded files:"
  while IFS=$'\t' read -r reason file; do
    echo "  - [$reason] $file"
  done < "$EXCLUDED_FILES"
fi
