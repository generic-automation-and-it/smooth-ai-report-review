#!/bin/bash
# insert-structural-risk.sh — place the Structural Risk block in the assembled
# review body without touching model prose (HLD-003 LADR-06).
#
# Usage: bash insert-structural-risk.sh <body.md> <block.md>
# Edits <body.md> in place. Always exits 0: a failed placement never fails a run.
#
# Placement, first that applies:
#   1. Both `## 🔍 Issues Summary` and a later `## 🎯 Recommendation` exist →
#      before the first `## ` heading after the Issues Summary. The block is its
#      own `##` section, so every section-bounded parser (Issues Summary until
#      the next `## `, Suggested Fixes until Recommendation) reads exactly what
#      it read without the block.
#   2. Otherwise (fail-closed stub, incremental body missing a heading, malformed
#      orchestrator answer) → after the header/Coverage-banner region, i.e.
#      before the first `---` rule.
#   3. Otherwise → appended at the end of the body.
set -u

body="${1:-}"
block="${2:-}"
[ -n "$body" ] && [ -f "$body" ] && [ -n "$block" ] && [ -s "$block" ] || exit 0

tmp="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$tmp"' EXIT

# Anchors are found only outside fenced code: a review quoting `## …` headings
# (or a `---` rule) inside a code block must not become a placement boundary.
# Fence tracking mirrors lib/strip-holistic-section.sh (0-3 leading spaces,
# ``` or ~~~, closing run at least as long, same character).
awk -v blockfile="$block" '
  function fence_run(s, ch,   k) {
    k = 0
    while (substr(s, k + 1, 1) == ch) k++
    return k
  }
  function fence_step(line,   pos, s, c, k, info) {
    pos = match(line, /[^ ]/)
    if (pos < 1 || pos > 4) return
    s = substr(line, pos)
    c = substr(s, 1, 1)
    if (c != "`" && c != "~") return
    k = fence_run(s, c)
    if (!open) {
      info = substr(s, k + 1)
      if (k >= 3 && !(c == "`" && info ~ /`/)) { open = 1; fchar = c; flen = k }
    } else if (c == fchar && k >= flen && substr(s, k + 1) ~ /^[ \t]*$/) {
      open = 0
    }
  }
  function emit_block(   l) {
    while ((getline l < blockfile) > 0) print l
    close(blockfile)
    print ""
    done = 1
  }
  {
    lines[NR] = $0
    was_open = open
    fence_step($0)
    # A line is structural only when it is outside a fence and not a fence line.
    plain[NR] = (!was_open && !open)
  }
  END {
    for (i = 1; i <= NR; i++) {
      if (!plain[i]) continue
      if (issues == 0 && lines[i] ~ /^## 🔍 Issues Summary/) issues = i
      else if (issues > 0 && rec == 0 && lines[i] ~ /^## 🎯 Recommendation/) rec = i
      if (rule == 0 && lines[i] == "---") rule = i
    }
    if (issues > 0 && rec > 0) {
      for (i = issues + 1; i <= rec; i++) if (plain[i] && lines[i] ~ /^## /) { target = i; break }
    } else if (rule > 0) {
      target = rule
    }
    for (i = 1; i <= NR; i++) {
      if (i == target && !done) emit_block()
      print lines[i]
    }
    if (!done) { print ""; emit_block() }
  }
' "$body" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && cat "$tmp" > "$body"
exit 0
