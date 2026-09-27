#!/bin/bash
# holistic-section.sh — find the orchestrator's Holistic Cross-Chunk Analysis
# and put it where a reader looks for it (LADR-063 amendment, LADR-099).
#
# Usage:
#   holistic-section.sh split <pr_summary.md> <main_out> <holistic_out>
#   holistic-section.sh place <main_md> <holistic_md>
#
# split — separates the orchestrator's output into the main body and the
#   holistic section. The prompt asks for a `DETAILED_SECTION_MARKER` line
#   before the holistic heading, but models drop it: 21 of 22 consecutive
#   reviews on this repo had no marker. The old fallback copied the WHOLE
#   output into the main body and wrote a "No holistic analysis section found."
#   placeholder as the holistic file. That did two kinds of damage:
#     - the holistic section was posted in the main body, unnumbered, with
#       the model's own `1)`/`2)` numbers — which point at the Issues Summary
#       the model wrote, not the merged one that replaced it;
#     - the Recommendation sync reads the holistic file for Critical/High
#       cross-chunk items, so it read the placeholder and a holistic blocker
#       could not block.
#   So the heading is the second anchor: the holistic section runs from
#   `## 🔄 Holistic Cross-Chunk Analysis` to the next main-body heading (or the
#   end). Everything else is main body. The marker line and the `---` rules
#   around it are dropped. The template's scaffolding between the heading and
#   `**Cross-Chunk Issues Found:**` ("Purpose", "What we looked for") is
#   dropped too — it is the prompt talking, not a finding. With neither anchor
#   the holistic file is left EMPTY: an absent section is honest, a placeholder
#   heading claiming "not found" is noise.
#
# place — inserts the holistic file into the main body directly after the
#   Issues Summary section (before the next `## ` heading), because it is part
#   of the overview: items only visible across chunks. No Issues Summary →
#   before the Recommendation; neither → appended. An empty holistic file is a
#   no-op.
#
# Both are fence-aware (a heading inside a code block is not a heading) and
# best-effort: on any problem the outputs keep their prior content, split then
# falls back to "everything is main body", and the script exits 0.
set -uo pipefail

HEADING='## 🔄 Holistic Cross-Chunk Analysis'

cmd="${1:-}"

case "$cmd" in
  split)
    in="${2:-}"; main_out="${3:-}"; hol_out="${4:-}"
    [ -n "$in" ] && [ -n "$main_out" ] && [ -n "$hol_out" ] || exit 0
    if [ ! -s "$in" ]; then
      : > "$main_out"; : > "$hol_out"
      exit 0
    fi
    if ! awk -v heading="$HEADING" -v main_out="$main_out" -v hol_out="$hol_out" '
      # Fence tracking as in CommonMark (and aggregate-reviews.sh): a closer
      # must use the opener character, be at least as long, and carry nothing
      # else. A bare toggle let a three-backtick line inside a four-backtick
      # example end the fence early, so an example heading counted as real.
      function fence_run(s, ch,   n) {
        n = 0
        while (substr(s, n + 1, 1) == ch) n++
        return n
      }
      function fence_step(line,   pos, s, c, n, info) {
        pos = match(line, /[^ ]/)
        if (pos < 1 || pos > 4) return
        s = substr(line, pos)
        c = substr(s, 1, 1)
        if (c != "`" && c != "~") return
        n = fence_run(s, c)
        if (!open) {
          info = substr(s, n + 1)
          if (n >= 3 && !(c == "`" && info ~ /`/)) { open = 1; fchar = c; flen = n }
        } else if (c == fchar && n >= flen && substr(s, n + 1) ~ /^[ \t]*$/) {
          open = 0
        }
      }
      function is_main_heading(s) {
        return s ~ /^## 📋 Overall Summary/ || s ~ /^## ✅ Positive Highlights/ ||
               s ~ /^## 🔍 Issues Summary/  || s ~ /^## 📝 Suggested Fixes/ ||
               s ~ /^## 🎯 Recommendation/
      }
      function flush_main_trailing_rules(   i) {
        # Drop the `---` rule(s) and blank lines that led up to the marker.
        while (mn > 0 && (main[mn] ~ /^[[:space:]]*$/ || main[mn] ~ /^[[:space:]]*---+[[:space:]]*$/)) mn--
      }
      BEGIN { open = 0; mode = "main"; mn = 0; hn = 0; lead = 0; saw_heading = 0 }
      {
        line = $0
        fence_step(line)
        if (!open) {
          if (line ~ /^[[:space:]]*DETAILED_SECTION_MARKER[[:space:]]*$/) {
            flush_main_trailing_rules()
            mode = "hol"; lead = 1
            next
          }
          if (index(line, heading) == 1) {
            mode = "hol"; lead = 0
            saw_heading = 1
            hol[++hn] = line
            next
          }
          if (mode == "hol" && is_main_heading(line)) { mode = "main" }
        }
        if (mode == "hol") {
          # Skip the `---` and blanks that follow the marker.
          if (lead && (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*---+[[:space:]]*$/)) next
          lead = 0
          hol[++hn] = line
        } else {
          main[++mn] = line
        }
      }
      END {
        # Main body: trim trailing rules/blank lines left where the section was.
        flush_main_trailing_rules()
        for (i = 1; i <= mn; i++) print main[i] > main_out
        if (mn == 0) printf "" > main_out
        # Holistic: drop trailing rules/blanks, then the template scaffolding.
        while (hn > 0 && (hol[hn] ~ /^[[:space:]]*$/ || hol[hn] ~ /^[[:space:]]*---+[[:space:]]*$/)) hn--
        if (hn == 0) { printf "" > hol_out; exit 0 }
        anchor = 0
        for (i = 1; i <= hn; i++) if (hol[i] ~ /^\*\*Cross-Chunk Issues Found:\*\*/) { anchor = i; break }
        print heading > hol_out
        print "" > hol_out
        start = 1
        if (anchor) start = anchor
        else if (index(hol[1], heading) == 1) start = 2
        while (start <= hn && hol[start] ~ /^[[:space:]]*$/) start++
        for (i = start; i <= hn; i++) print hol[i] > hol_out
      }
    ' "$in" 2>/dev/null; then
      cp "$in" "$main_out" 2>/dev/null || true
      : > "$hol_out"
    fi
    [ -f "$main_out" ] || cp "$in" "$main_out" 2>/dev/null || true
    [ -f "$hol_out" ] || : > "$hol_out"
    exit 0
    ;;

  place)
    main="${2:-}"; hol="${3:-}"
    [ -n "$main" ] && [ -f "$main" ] || exit 0
    [ -n "$hol" ] && [ -s "$hol" ] || exit 0
    tmp="$(mktemp 2>/dev/null)" || exit 0
    if grep -q '^## 🔍 Issues Summary' "$main"; then target="after_issues"
    elif grep -q '^## 🎯 Recommendation' "$main"; then target="before_rec"
    else target="append"
    fi
    awk -v hol="$hol" -v target="$target" '
      # Fence tracking as in CommonMark (and aggregate-reviews.sh): a closer
      # must use the opener character, be at least as long, and carry nothing
      # else. A bare toggle let a three-backtick line inside a four-backtick
      # example end the fence early, so an example heading counted as real.
      function fence_run(s, ch,   n) {
        n = 0
        while (substr(s, n + 1, 1) == ch) n++
        return n
      }
      function fence_step(line,   pos, s, c, n, info) {
        pos = match(line, /[^ ]/)
        if (pos < 1 || pos > 4) return
        s = substr(line, pos)
        c = substr(s, 1, 1)
        if (c != "`" && c != "~") return
        n = fence_run(s, c)
        if (!open) {
          info = substr(s, n + 1)
          if (n >= 3 && !(c == "`" && info ~ /`/)) { open = 1; fchar = c; flen = n }
        } else if (c == fchar && n >= flen && substr(s, n + 1) ~ /^[ \t]*$/) {
          open = 0
        }
      }
      function emit(   l) {
        while ((getline l < hol) > 0) print l
        close(hol)
        print ""
        done = 1
      }
      BEGIN { open = 0; state = 0; done = 0 }
      {
        fence_step($0)
        if (!open && !done) {
          if (target == "after_issues") {
            if (state == 0 && $0 ~ /^## 🔍 Issues Summary/) { state = 1; print; next }
            if (state == 1 && $0 ~ /^## /) emit()
          } else if (target == "before_rec" && $0 ~ /^## 🎯 Recommendation/) {
            emit()
          }
        }
        print
      }
      END {
        if (!done) { print ""; while ((getline l < hol) > 0) print l; close(hol) }
      }
    ' "$main" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
    # Never replace the main body with something shorter than it was.
    if [ -s "$tmp" ] && [ "$(wc -l < "$tmp")" -ge "$(wc -l < "$main")" ]; then
      cat "$tmp" > "$main"
    fi
    rm -f "$tmp"
    exit 0
    ;;

  *)
    echo "usage: holistic-section.sh split <in> <main_out> <holistic_out> | place <main> <holistic>" >&2
    exit 0
    ;;
esac
