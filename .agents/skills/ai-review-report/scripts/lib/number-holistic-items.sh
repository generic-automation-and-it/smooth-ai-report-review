#!/bin/bash
# number-holistic-items.sh — assign stable `H<n>)` numbers to the items in the
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
#   - Lines that already carry a number, so a re-run is idempotent. The guard
#     accepts the pre-LADR-067 `**#H1**` shape too, so a re-run over a review
#     rendered by an older gate does not double-number it.
#
# A number the model wrote itself at the head of an item (`**2) [VERIFIED]**`,
# `**2)**`, `2)`) is removed and replaced by the H number (LADR-099).
#
# The `H` prefix keeps this sequence separate from the findings' bare `N)`
# (assigned by merge-findings.py) and from the renderer's `R`/`T`/`P`, so
# adding an item to one class never renumbers another.
#
# LADR-067: the identifier is `H1)`, not `#H1`. `#H1` never autolinked — only
# `#` + digits does — but the whole scheme moved together so that no consumer
# has to remember which of the five sequences is safe to write bare in prose.
# The number stays BOLDED at the head of the bullet: `1)` is a CommonMark
# ordered-list marker, and `- H1) foo` is fine only because it starts with a
# letter. Keeping every class bolded means that distinction never has to hold.
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

  BEGIN { started = 0; open = 0; n = 0 }

  # Track fenced blocks so a bullet inside an example block is left alone. A
  # fence line itself, and every line inside one, is printed as is.
  { was = open; fence_step($0); if (was || open) { print; next } }

  /^\*\*Cross-Chunk Issues Found:\*\*/ { started = 1; print; next }
  !started { print; next }

  # Top-level bullet: `- ` or `* ` at column 0. Indented bullets are
  # continuations of the item above and must not consume a number.
  /^[-*] / {
    payload = substr($0, 3)

    # Already numbered (idempotent re-run). Matches the current `**H1)**` shape
    # and the pre-LADR-067 `**#H1**` one. Only the H class counts: a bare
    # `**2)**` is a model number, handled below.
    if (payload ~ /^\*\*#H[0-9]/ || payload ~ /^\*\*H[0-9]+\)\*\*/) { print; next }

    # LADR-099: drop a number the MODEL put at the head of the item. The prompt
    # used to ask for one stable `1)` per finding in every section, so the
    # model wrote `- **2) [VERIFIED]** …` here, citing the Issues Summary IT
    # wrote. That summary is replaced by the merged one, numbered differently,
    # so the model number pointed at a different finding (review 5330810275:
    # holistic `2)` was merged finding 1). The H number replaces it.
    if (payload ~ /^\*\*#?[0-9]+[.)]?\*\*[[:space:]]*/) sub(/^\*\*#?[0-9]+[.)]?\*\*[[:space:]]*/, "", payload)
    else if (payload ~ /^\*\*#?[0-9]+[.)][[:space:]]+/) sub(/^\*\*#?[0-9]+[.)][[:space:]]+/, "**", payload)
    else if (payload ~ /^#?[0-9]+[.)][[:space:]]+/) sub(/^#?[0-9]+[.)][[:space:]]+/, "", payload)

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
    printf "%s **H%d)** %s\n", substr($0, 1, 1), n, payload
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
