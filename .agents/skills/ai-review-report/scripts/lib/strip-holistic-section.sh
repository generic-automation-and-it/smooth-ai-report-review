#!/bin/bash
# strip-holistic-section.sh — remove a holistic section from the orchestrator's
# summary (LADR-100).
#
# Usage: strip-holistic-section.sh <pr_summary.md> <main_out>
#
# The review has one overview: the Issues Summary, built from the merged chunk
# findings. The separate "Holistic Cross-Chunk Analysis" was dropped because it
# mostly restated those findings under different numbers and never changed a
# verdict (LADR-100). The prompt no longer asks for it, but a model may still
# write one from habit — the old `DETAILED_SECTION_MARKER` line, or the
# `## 🔄 Holistic Cross-Chunk Analysis` heading. Either starts the section; it
# ends at the next main-body heading (Overall Summary, Positive Highlights,
# Issues Summary, Suggested Fixes, Recommendation) or at the end. The marker's
# `---` rules go with it.
#
# Fence-aware as in CommonMark: a closer uses the opener's character, is at
# least as long and carries nothing else, so a heading inside a code example is
# not a heading.
#
# Best-effort: on any problem <main_out> is the input unchanged, and the script
# exits 0.
set -uo pipefail

in="${1:-}"; out="${2:-}"
[ -n "$in" ] && [ -n "$out" ] || exit 0
if [ ! -s "$in" ]; then
  : > "$out"
  exit 0
fi

if ! awk -v heading='## 🔄 Holistic Cross-Chunk Analysis' '
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
  function is_main_heading(s) {
    return s ~ /^## 📋 Overall Summary/ || s ~ /^## ✅ Positive Highlights/ ||
           s ~ /^## 🔍 Issues Summary/  || s ~ /^## 📝 Suggested Fixes/ ||
           s ~ /^## 🎯 Recommendation/
  }
  function trim_trailing_rules() {
    while (n > 0 && (keep[n] ~ /^[[:space:]]*$/ || keep[n] ~ /^[[:space:]]*---+[[:space:]]*$/)) n--
  }
  BEGIN { open = 0; drop = 0; n = 0 }
  {
    line = $0
    fence_step(line)
    if (!open) {
      if (line ~ /^[[:space:]]*DETAILED_SECTION_MARKER[[:space:]]*$/ || index(line, heading) == 1) {
        if (!drop) trim_trailing_rules()
        drop = 1
        next
      }
      if (drop && is_main_heading(line)) { drop = 0; keep[++n] = ""; }
    }
    if (!drop) keep[++n] = line
  }
  END {
    trim_trailing_rules()
    for (i = 1; i <= n; i++) print keep[i]
  }
' "$in" > "$out" 2>/dev/null; then
  cp "$in" "$out" 2>/dev/null || true
fi
[ -s "$out" ] || cp "$in" "$out" 2>/dev/null || true
exit 0
