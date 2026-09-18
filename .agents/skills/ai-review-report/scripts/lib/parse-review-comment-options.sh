#!/usr/bin/env bash
# Parse optional review-scope controls on the same line as /ai-review.
#
# Usage:
#   parse_review_comment_options "$comment" file_limit_var deleted_var generated_paths_var
#
# The caller provides variable names so generated paths can remain newline-delimited
# without shell evaluation. This requires Bash 4's printf -v, which the gate already
# requires. Unknown prose remains valid for backward-compatible `/ai-review please`
# comments; unknown --switches fail loudly instead of being silently ignored.
parse_review_comment_options() {
  local comment="$1" file_limit_var="$2" deleted_var="$3" generated_paths_var="$4"
  local line command_line="" token path
  local -a args=()
  local i=0 command_index=-1 file_limit="" exclude_deleted="0" generated_paths=""

  while IFS= read -r line; do
    case "$line" in
      *"/ai-review"*) command_line="$line"; break ;;
    esac
  done <<< "$comment"

  [ -n "$command_line" ] || return 0
  read -r -a args <<< "$command_line"
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "/ai-review" ]; then
      command_index=$i
      break
    fi
  done
  [ "$command_index" -ge 0 ] || return 0

  i=$((command_index + 1))
  while [ "$i" -lt "${#args[@]}" ]; do
    token="${args[$i]}"
    case "$token" in
      --file-limit)
        i=$((i + 1))
        if [ "$i" -ge "${#args[@]}" ] || ! [[ "${args[$i]}" =~ ^[1-9][0-9]*$ ]]; then
          echo "❌ /ai-review --file-limit requires a positive integer." >&2
          return 1
        fi
        file_limit="${args[$i]}"
        ;;
      --exclude-deleted)
        exclude_deleted="1"
        ;;
      --exclude-generated)
        i=$((i + 1))
        if [ "$i" -ge "${#args[@]}" ]; then
          echo "❌ /ai-review --exclude-generated requires a repo-relative path." >&2
          return 1
        fi
        path="${args[$i]}"
        case "$path" in
          ""|--*|/*|.|..|../*|*/../*|*/..)
            echo "❌ /ai-review --exclude-generated path must stay inside the repository: '$path'." >&2
            return 1
            ;;
        esac
        if [ -n "$generated_paths" ]; then
          generated_paths+=$'\n'
        fi
        generated_paths+="$path"
        ;;
      --*)
        echo "❌ Unknown /ai-review option: $token" >&2
        return 1
        ;;
      *)
        # Existing comments may add prose after /ai-review. Preserve that behavior.
        ;;
    esac
    i=$((i + 1))
  done

  printf -v "$file_limit_var" '%s' "$file_limit"
  printf -v "$deleted_var" '%s' "$exclude_deleted"
  printf -v "$generated_paths_var" '%s' "$generated_paths"
}
