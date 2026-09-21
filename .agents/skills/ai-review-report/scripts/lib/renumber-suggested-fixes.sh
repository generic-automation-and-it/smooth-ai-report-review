#!/bin/bash
# renumber-suggested-fixes.sh — repoint the `finding N` cross-references inside
# `## 📝 Suggested Fixes` at the merged finding set (issue #125, LADR-055).
#
# Usage:
#   renumber-suggested-fixes.sh <merged_json> <summary_md>
#
# WHY THIS EXISTS
#
# The orchestrator writes ONE numbering across the report it produces: the
# Formatting Rules in aggregate-reviews.sh tell it to "reuse one stable `1)`
# identifier per finding across every section it appears in", so its Suggested
# Fixes blocks cross-reference its own Issues Summary. LADR-055 then REPLACES
# that Issues Summary with one rendered from the merged sidecars, and
# merge-findings.py numbers by severity then confidence — an order the
# orchestrator never saw. Every `finding N` in Suggested Fixes is left pointing
# at whatever now occupies slot N.
#
# That is not theoretical. Consumer PR #95, run 35640330645: the merge put
# `AGENTS.md:85` first (confidence 100) where the chunk had it third, and three
# of the four fix blocks ended up naming a different file than the finding they
# cited — a reader quoting "finding 3" to `/ai-review` asked for a fix to a file
# the block above it never mentioned. The fourth was right by coincidence, and
# the fifth cited a finding the merge had suppressed, so it named a number that
# existed nowhere in the posted body.
#
# THE MAPPING
#
# The original issue-#125 note conceded there was "no deterministic mapping from
# a prose fix paragraph back to a merged finding". That is true of the PROSE. It
# is not true of the block, which is anchored by a heading the prompt mandates:
#
#   ### `path/to/file.ext:line_number`
#
# file plus line is exactly the key merge-findings.py dedupes on, so the anchor
# resolves without reading a word of the prose. Resolution is deliberately
# conservative, because a confidently wrong number is worse than the status quo:
#
#   - file must match (after normalising a leading `./`), and then
#   - the finding line must fall inside the heading line-spec (`7`, `52-53`,
#     `87,161` are all real shapes), else inside it widened by $TOLERANCE lines
#     to absorb the drift between a model-quoted range and the sidecar line.
#   - exactly one survivor -> rewrite the number.
#   - more than one survivor -> AMBIGUOUS, leave the reference untouched. There
#     is no honest answer and guessing reintroduces the defect.
#   - no survivor -> the block describes something the merge suppressed, demoted
#     or dropped, so it genuinely has no number: say so in words rather than
#     leave a number that resolves to a different file.
#
# Rewrites are confined to the Suggested Fixes section and skip fenced code, so
# a diff that happens to contain the word "finding" is never edited. Plural or
# range references (`findings 1-4`, `findings 1, 2`) are left alone: one anchor
# cannot resolve a set. The holistic and per-chunk sections are out of scope by
# design — LADR-005 keeps them verbatim.
#
# Idempotent: a second run maps each anchor to the same number, and the
# no-number wording carries no digits to re-match.
#
# No-ops (exit 0, file untouched) when: inputs are missing, jq is absent, the
# merged document is not `complete`, there is no Suggested Fixes heading, or
# nothing needed rewriting. Best-effort by construction, exactly like
# annotate-suggested-fixes.sh — a stale number is cosmetic, a mangled report
# is not.
#
# LADR-067: nothing emitted here may contain `#` followed by digits.
set -uo pipefail

merged="${1:-}"
summary="${2:-}"

# How far a heading line-spec may miss the sidecar line and still resolve. The
# heading is model prose quoting a hunk ("81-83" for a finding recorded at 83),
# so it drifts by a few lines routinely. Wide enough to absorb that, far
# narrower than the gap between two distinct findings in one file — on run
# 35640330645 the two `docs/wiki/ci.md` items sat 35 lines apart and stayed
# correctly distinguished.
TOLERANCE=10

[ -n "$merged" ] && [ -s "$merged" ] || exit 0
[ -n "$summary" ] && [ -f "$summary" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e '.status == "complete"' "$merged" >/dev/null 2>&1 || exit 0
grep -q '^## 📝 Suggested Fixes' "$summary" || exit 0

# number<TAB>file<TAB>line, one per merged finding. Only `.findings[]` — the
# suppressed and pre-existing arrays carry no number in the posted body, and
# resolving an anchor onto one of them would re-create the defect in reverse.
map="$(jq -r '
  (.findings // [])[]
  | select((.["#"] // null) != null)
  | [ (.["#"] | tostring), (.file // ""), ((.line // 0) | tostring) ]
  | @tsv
' "$merged" 2>/dev/null)" || exit 0

tmp="$(mktemp)" || exit 0
trap 'rm -f "$tmp" "$tmp.counts"' EXIT

# NOTE for editors: this awk program is a single-quoted shell string, so an
# apostrophe anywhere in its comments terminates the string and the script dies
# with a syntax error. Use "the anchor" rather than the possessive form.
awk -v mapdata="$map" -v tol="$TOLERANCE" '
  function norm(p) {
    sub(/^\.\//, "", p); sub(/^\//, "", p)
    return p
  }
  # Does line n fall inside spec (a comma-separated list of N or A-B), widened
  # by slack on both ends?
  function in_spec(n, spec, slack,   parts, i, k, lo, hi, tokn) {
    k = split(spec, parts, ",")
    for (i = 1; i <= k; i++) {
      tokn = parts[i]
      gsub(/[ \t]/, "", tokn)
      if (tokn == "") continue
      if (tokn ~ /^[0-9]+-[0-9]+$/) {
        lo = tokn; sub(/-.*$/, "", lo)
        hi = tokn; sub(/^.*-/, "", hi)
      } else if (tokn ~ /^[0-9]+$/) {
        lo = tokn; hi = tokn
      } else {
        continue
      }
      if (n >= lo - slack && n <= hi + slack) return 1
    }
    return 0
  }
  # Returns the finding number, "" for ambiguous, or "0" for no such finding.
  function resolve(path, spec,   i, hits, hitn, tier, slack, matched, last) {
    path = norm(path)
    hitn = 0
    for (i = 1; i <= nmap; i++) {
      if (norm(mfile[i]) != path) continue
      hits[++hitn] = i
    }
    if (hitn == 0) return "0"
    if (spec == "") return (hitn == 1) ? mnum[hits[1]] : ""
    for (tier = 0; tier <= 1; tier++) {
      slack = (tier == 0) ? 0 : tol
      matched = 0; last = 0
      for (i = 1; i <= hitn; i++) {
        if (in_spec(mline[hits[i]] + 0, spec, slack)) { matched++; last = hits[i] }
      }
      if (matched == 1) return mnum[last]
      if (matched > 1) return ""
    }
    return "0"
  }
  function rewrite(s,   out, rest, pre, m, word, after, target) {
    out = ""; rest = s
    while (match(rest, /[Ff]indings?[ \t]+[0-9]+/)) {
      pre = substr(rest, 1, RSTART - 1)
      m   = substr(rest, RSTART, RLENGTH)
      after = substr(rest, RSTART + RLENGTH, 1)
      rest = substr(rest, RSTART + RLENGTH)
      # A range or a list continues past this number, so one anchor cannot
      # resolve it. Leave the whole reference exactly as the model wrote it.
      if (after == "-" || after == ",") { out = out pre m; continue }
      if (anchor_state == "ambig") { out = out pre m; continue }
      if (anchor_state == "none") {
        word = (m ~ /^F/) ? "No numbered finding" : "no numbered finding"
        out = out pre word
        changed = 1
        continue
      }
      word = m; sub(/[ \t]+[0-9]+$/, "", word)
      target = word " " anchor_num
      if (target != m) changed = 1
      out = out pre target
    }
    return out rest
  }
  BEGIN {
    nmap = 0
    n = split(mapdata, rows, "\n")
    for (i = 1; i <= n; i++) {
      if (rows[i] == "") continue
      split(rows[i], f, "\t")
      nmap++
      mnum[nmap] = f[1]; mfile[nmap] = f[2]; mline[nmap] = f[3]
    }
    in_fixes = 0; in_fence = 0; anchor_state = "ambig"; anchor_num = ""
    changed = 0; remapped = 0; cleared = 0
  }
  {
    line = $0
    if (line ~ /^## 📝 Suggested Fixes/) { in_fixes = 1; in_fence = 0; anchor_state = "ambig"; print; next }
    if (in_fixes && line ~ /^## / ) { in_fixes = 0 }
    if (!in_fixes) { print; next }

    if (line ~ /^[ \t]*(```|~~~)/) { in_fence = !in_fence; print; next }
    if (in_fence) { print; next }

    if (line ~ /^###/) {
      # Exactly one backtick-quoted token is an anchor. Two means the heading
      # covers several files and no single finding owns the block.
      nt = gsub(/`/, "`", line)
      if (nt == 2) {
        inner = line
        sub(/^[^`]*`/, "", inner)
        sub(/`.*$/, "", inner)
        spec = inner; path = inner
        if (match(inner, /:[0-9]+([,-][0-9]+)*[ \t]*$/)) {
          path = substr(inner, 1, RSTART - 1)
          spec = substr(inner, RSTART + 1)
          gsub(/[ \t]/, "", spec)
        } else {
          spec = ""
        }
        r = resolve(path, spec)
        if (r == "")       { anchor_state = "ambig"; anchor_num = "" }
        else if (r == "0") { anchor_state = "none";  anchor_num = "" }
        else               { anchor_state = "num";   anchor_num = r }
      } else {
        anchor_state = "ambig"; anchor_num = ""
      }
      print; next
    }

    before = line
    line = rewrite(line)
    if (line != before) {
      if (anchor_state == "none") cleared++; else remapped++
    }
    print line
  }
  END { printf("%d %d\n", remapped, cleared) > "/dev/stderr" }
' "$summary" > "$tmp" 2>"$tmp.counts"
# An awk that died halfway leaves a truncated $tmp, so its status gates
# everything below. The counts channel is shared with awk diagnostics (a runtime
# warning prints there too), hence the LAST line only — and anything that is not
# two integers falls through the numeric guard to a clean no-op rather than a
# partial rewrite.
_awk_rc=$?
counts="$(tail -n 1 "$tmp.counts" 2>/dev/null || echo "0 0")"
rm -f "$tmp.counts"
[ "$_awk_rc" -eq 0 ] || exit 0
remapped="${counts%% *}"
cleared="${counts##* }"
case "$remapped" in ''|*[!0-9]*) remapped=0 ;; esac
case "$cleared"  in ''|*[!0-9]*) cleared=0 ;; esac

if [ "$remapped" -eq 0 ] && [ "$cleared" -eq 0 ]; then
  exit 0
fi

# A rewrite that lost lines is a bug, not an improvement — leave the file alone.
# `wc -l` pads its output with spaces on BSD/macOS; strip it, or the numeric
# guard below rejects every value and the remap is never applied.
before=$(wc -l < "$summary" 2>/dev/null | tr -d '[:space:]' || echo 0)
after=$(wc -l < "$tmp" 2>/dev/null | tr -d '[:space:]' || echo 0)
before="${before:-0}"; after="${after:-0}"
case "$before$after" in *[!0-9]*) exit 0 ;; esac
[ "$after" -eq "$before" ] || exit 0
[ -s "$tmp" ] || exit 0

mv "$tmp" "$summary" || exit 0
trap - EXIT
echo "Renumbered Suggested Fixes against merged findings: repointed=${remapped} unnumbered=${cleared}" >&2
exit 0
