#!/bin/bash
# strip-structural-risk.sh — remove the Structural Risk block from a body on
# stdin: its `## 🧭 Structural Risk (graph)` heading, the first begin..end
# marker pair under it inclusive, and the blank line the inserter leaves after
# it. A begin marker without that heading directly above it, or without an end
# marker (prose quoting either), strips nothing. The posted-body size ladder runs this before any truncation,
# so the block is dropped whole and never cut mid-way (HLD-001 Goal 4).
awk '
  { lines[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] == "<!-- ai-review-report:structural-risk:begin -->" && i > 1 &&
          lines[i - 1] == "## 🧭 Structural Risk (graph)") {
        for (j = i + 1; j <= NR; j++) {
          if (lines[j] == "<!-- ai-review-report:structural-risk:end -->") { b = i - 1; e = j; break }
        }
        break
      }
    }
    if (b && e < NR && lines[e + 1] == "") e++
    for (i = 1; i <= NR; i++) if (!b || i < b || i > e) print lines[i]
  }
'
