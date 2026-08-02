#!/bin/bash
# build-blame-digest.sh — precomputed git blame for changed line ranges (LADR-061).
#
# For each file in a chunk, blame the changed line ranges at HEAD_SHA and emit a
# deduplicated commit digest. Never dumps full-file blame; never emits per-line
# rows.
#
# Blame is taken at HEAD_SHA deliberately: a line added by this PR blames to this
# PR's own commit, which is exactly the evidence needed to answer "was this
# introduced by THIS diff?" — the question LADR-015's multi-commit staleness
# problem leaves open.
#
# Inputs (env vars):
#   HEAD_SHA — the commit to blame at (captured at dispatch time)
#   FROM_SHA — the diff base (used to compute changed line ranges)
#
# Input (stdin): NUL-delimited list of changed file paths (same format as
#   ci_temp/changed_files.txt).
#
# Output (stdout): one line per distinct commit, deduplicated:
#   <shortsha> <author> <date> <subject> | <file1>,<file2>,...
#
# On any failure (shallow clone, missing object, deleted file, timeout) the
# affected file is skipped and the script still exits 0 — the caller treats
# empty output as "no digest" and emits no prompt block.
#
# The `review` agent cannot run git (LADR-029) and that does not change. This
# script is the precompute half of that constraint: bash gathers the provenance,
# the model only reads it.

set -uo pipefail

HEAD_SHA="${HEAD_SHA:-}"
FROM_SHA="${FROM_SHA:-}"

# Hard cap on distinct commits reported, so a chunk touching a long-lived file
# cannot blow the prompt budget (LADR-035).
MAX_COMMITS="${BLAME_DIGEST_MAX_COMMITS:-40}"

if [ -z "$HEAD_SHA" ] || [ -z "$FROM_SHA" ]; then
  exit 0
fi

command -v git >/dev/null 2>&1 || exit 0

files=()
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  files+=("$f")
done

[ ${#files[@]} -eq 0 ] && exit 0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for file in "${files[@]}"; do
  # A file deleted by this diff has no lines to blame at HEAD.
  [ -f "$file" ] || continue

  # Hunk headers: @@ -old_start[,old_count] +new_start[,new_count] @@
  # Only the post-image (+) side matters — we blame the file as it stands at
  # HEAD_SHA, so the pre-image line numbers are meaningless here.
  hunks="$(git diff "${FROM_SHA}" "${HEAD_SHA}" -- "$file" 2>/dev/null | grep -E '^@@' || true)"
  [ -z "$hunks" ] && continue

  # Build one -L argument per hunk. `git blame` accepts -L repeatedly; it does
  # NOT accept several ranges inside a single -L argument, which is why these
  # are collected into an array rather than a space-joined string.
  blame_args=()
  while IFS= read -r hunk; do
    [ -z "$hunk" ] && continue
    new_start="$(printf '%s' "$hunk" | sed -nE 's/^@@ -[0-9]+(,[0-9]+)? \+([0-9]+)(,[0-9]+)? @@.*/\2/p')"
    new_count="$(printf '%s' "$hunk" | sed -nE 's/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+,([0-9]+) @@.*/\2/p')"
    [ -z "$new_start" ] && continue
    # A hunk header with no explicit count means exactly one line.
    [ -z "$new_count" ] && new_count=1
    # A pure-deletion hunk reports +N,0 — there is no post-image line to blame.
    [ "$new_count" -eq 0 ] 2>/dev/null && continue
    end_line=$((new_start + new_count - 1))
    blame_args+=(-L "${new_start},${end_line}")
  done <<< "$hunks"

  [ ${#blame_args[@]} -eq 0 ] && continue

  # --line-porcelain guarantees a full 40-char SHA at the start of each record.
  # Default `git blame` output abbreviates the SHA, so a 40-char match would
  # find nothing — the failure that made the first implementation silently
  # produce an empty digest even when everything else was wired correctly.
  # -C detects lines moved from elsewhere in the same commit; the repeated -C
  # forms are deliberately not used (they are expensive on large files and the
  # extra provenance is not worth a per-chunk timeout).
  blame_output="$(git blame --line-porcelain -C "${blame_args[@]}" "${HEAD_SHA}" -- "$file" 2>/dev/null || true)"
  [ -z "$blame_output" ] && continue

  commit_shas="$(printf '%s\n' "$blame_output" | grep -oE '^[0-9a-f]{40}' | sort -u || true)"
  [ -z "$commit_shas" ] && continue

  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    info="$(git log -1 --format='%h %an %as %s' "$sha" 2>/dev/null || true)"
    [ -z "$info" ] && continue
    # Subjects can contain '|'; the reader splits on the LAST ' | ' separator,
    # and the file list never contains one.
    printf '%s\t%s\n' "$info" "$file" >> "$TMP_DIR/digest.txt"
  done <<< "$commit_shas"
done

[ -f "$TMP_DIR/digest.txt" ] || exit 0

# Group by commit, dedupe the file list, and cap the number of commits.
sort -u "$TMP_DIR/digest.txt" | awk -F'\t' -v max="$MAX_COMMITS" '
  {
    key = $1
    if (!(key in seen)) { order[++n] = key; seen[key] = 1 }
    if (index("," files[key] ",", "," $2 ",") == 0) {
      files[key] = (files[key] == "" ? $2 : files[key] "," $2)
    }
  }
  END {
    limit = (n < max ? n : max)
    for (i = 1; i <= limit; i++) print order[i] " | " files[order[i]]
    if (n > max) print "… " (n - max) " older commit(s) omitted"
  }
'
