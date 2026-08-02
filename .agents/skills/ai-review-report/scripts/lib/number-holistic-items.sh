#!/bin/bash
# number-holistic-items.sh — assign stable `#H<n>` numbers to the items in the
# orchestrator's Holistic Cross-Chunk Analysis (LADR-063).
#
# Usage: number-holistic-items.sh <holistic_markdown_file>
#
# Edits the file in place. On ANY problem — missing file, missing anchor,
# unwritable temp — it leaves the input untouched and exits 0. An unnumbered
# holistic section is a cosmetic loss; a mangled one is a corrupted review.
#
# Why this is deterministic post-processing rather than a prompt rule: the
# repo's standing position is that the model is untrusted for anything a script
# can decide (LADR-045/056 are the same argument applied to the fixer). A prompt
# that asks for numbering yields numbers that are plausible rather than
# sequential — duplicated, skipped, or restarted per subsection — and nothing
# downstream can tell the difference.
#
# What gets a number:
#   - Top-level `- ` bullets (column 0 only), i.e. one per holistic item.
#   - Only AFTER the `**Cross-Chunk Issues Found:**` anchor. The bullets above it
#     are the template's own "What we looked for:" checklist, which are prompt
#     scaffolding rather than findings. No anchor → nothing is numbered.
#
# What does not:
#   - Indented continuation bullets (they belong to the item above).
#   - Placeholder bullets ("None found", "N/A", "Not applicable", …) — these are
#     the template's empty-section markers, and numbering "N/A" is noise that
#     makes the real items harder to scan.
#   - Anything inside a fenced code block.
#   - Lines that already carry a `**#…**` number, so a re-run is idempotent.
#
# The `#H` prefix keeps this sequence separate from the findings' `#N`
# (assigned by merge-findings.py) and from the renderer's `#R`/`#T`/`#P`, so
# adding an item to one class never renumbers another.
set -uo pipefail

target="${1:-}"
[ -n "$target" ] || exit 0
[ -f "$target" ] || exit 0
[ -s "$target" ] || exit 0

# No anchor, nothing to do. Both the standard and the sync-mode holistic
# templates emit this line, so its absence means the model departed from the
# template and the structural assumptions below no longer hold.
grep -q '^\*\*Cross-Chunk Issues Found:\*\*' "$target" || exit 0

tmp="$(mktemp 2>/dev/null)" || exit 0

awk '
  BEGIN { started = 0; fence = 0; n = 0 }

  # Track fenced blocks so a bullet inside an example block is left alone.
  /^[[:space:]]*(```|~~~)/ { fence = !fence; print; next }
  fence { print; next }

  /^\*\*Cross-Chunk Issues Found:\*\*/ { started = 1; print; next }
  !started { print; next }

  # Top-level bullet: `- ` or `* ` at column 0. Indented bullets are
  # continuations of the item above and must not consume a number.
  /^[-*] / {
    payload = substr($0, 3)

    # Already numbered (idempotent re-run).
    if (payload ~ /^\*\*#/) { print; next }

    # Placeholder / not-applicable markers. Compare on a stripped, lowercased
    # copy so "**None found**", "_N/A_" and "None found." all match.
    probe = payload
    gsub(/[`*_"]/, "", probe)
    sub(/^[[:space:]]+/, "", probe)
    sub(/[[:space:]]+$/, "", probe)
    sub(/\.+$/, "", probe)
    lower = tolower(probe)
    if (lower == ""            || lower == "none"        || lower == "none found" ||
        lower == "none identified" || lower == "none present" ||
        lower == "none noted"  || lower == "none detected" ||
        lower == "no issues"   || lower == "no issues found" ||
        lower == "no concerns" || lower == "no concerns found" ||
        lower == "no problems" || lower == "no problems found" ||
        lower == "nothing found" || lower == "n/a" || lower == "na" ||
        lower == "not applicable") { print; next }

    # An "Additional Analysis" entry is `- **Label:** prose`; when the prose is
    # a placeholder ("**Dependency Injection Analysis:** Not applicable.") the
    # item is scaffolding too. Test the text after the first colon.
    if (payload ~ /:/) {
      rest = payload
      sub(/^[^:]*:/, "", rest)
      gsub(/[`*_"]/, "", rest)
      sub(/^[[:space:]]+/, "", rest)
      sub(/[[:space:]]+$/, "", rest)
      sub(/\.+$/, "", rest)
      rl = tolower(rest)
      if (rl == "n/a" || rl == "na" || rl == "not applicable" ||
          rl == "none" || rl == "none found" || rl == "none identified" ||
          rl == "nothing found") { print; next }
    }

    n++
    printf "%s **#H%d** %s\n", substr($0, 1, 1), n, payload
    next
  }

  { print }
' "$target" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }

# Never replace the original with an empty or truncated file. awk failing
# halfway would otherwise delete the entire holistic analysis, which is a far
# worse outcome than leaving it unnumbered.
if [ -s "$tmp" ] && [ "$(wc -l < "$tmp")" -eq "$(wc -l < "$target")" ]; then
  cat "$tmp" > "$target"
fi
rm -f "$tmp"
exit 0
