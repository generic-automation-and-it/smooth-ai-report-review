#!/bin/bash
# strip-structural-risk.sh — remove the Structural Risk block from a body on
# stdin: its `## 🧭 Structural Risk (graph)` heading, the first complete
# begin..end marker pair under it, and the blank line the inserter leaves after
# it. Markers are recognised only OUTSIDE fenced code — a review that quotes the
# heading and both markers inside an example must not pair the quoted begin with
# the genuine end, which would delete the real review content between them.
# A begin marker without that heading directly above it, or without an end
# marker, strips nothing. The posted-body size ladder runs this before any
# truncation, so the block is dropped whole and never cut mid-way (HLD-001 Goal 4).
awk '
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
  {
    lines[NR] = $0
    was_open = open
    fence_step($0)
    plain[NR] = (!was_open && !open)
  }
  END {
    for (i = 2; i <= NR; i++) {
      if (!plain[i] || !plain[i - 1]) continue
      if (lines[i] == "<!-- ai-review-report:structural-risk:begin -->" &&
          lines[i - 1] == "## 🧭 Structural Risk (graph)") {
        for (j = i + 1; j <= NR; j++) {
          if (plain[j] && lines[j] == "<!-- ai-review-report:structural-risk:end -->") { b = i - 1; e = j; break }
        }
        if (b) break
      }
    }
    if (b && e < NR && lines[e + 1] == "") e++
    for (i = 1; i <= NR; i++) if (!b || i < b || i > e) print lines[i]
  }
'
