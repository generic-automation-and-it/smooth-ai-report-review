#!/usr/bin/env bash
# Make the fixer's FIX/SKIP table render as a GitHub table in the summary comment.
# $1 (or stdin): the model's raw output. stdout: the same text, normalised.
#
# GitHub only draws a table that starts its own block. A model that writes a
# line such as `1. Proceeding from the runbooks.` directly above the header
# turns every row into lazy continuation text of that list item, and a table
# indented 4+ spaces becomes a code block. So each run of `|` lines is
# un-indented and fenced by blank lines; all other text, and anything inside a
# ``` / ~~~ code fence, passes through unchanged. Idempotent.
set -euo pipefail

awk '
  {
    line = $0
    sub(/\r$/, "", line)
    blank = (line ~ /^[[:space:]]*$/)
    if (line ~ /^[[:space:]]*(```|~~~)/) {
      if (in_table) { print ""; in_table = 0 }
      in_fence = !in_fence
    } else if (!in_fence && line ~ /^[[:space:]]*\|/) {
      if (!in_table && prev_text) print ""
      sub(/^[[:space:]]+/, "", line)
      in_table = 1
    } else if (in_table) {
      if (!blank) print ""
      in_table = 0
    }
    print line
    prev_text = !blank
  }
' "$@"
