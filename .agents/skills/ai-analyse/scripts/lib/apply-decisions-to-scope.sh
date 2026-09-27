#!/bin/bash
# apply-decisions-to-scope.sh — put the decision model's FIX/SKIP
# recommendations into the autonomous fixer's scope (LADR-097).
#
# Usage: apply-decisions-to-scope.sh <recommendations.tsv> [withhold.txt] [report_file] < section > section
#
# stdin:  one severity section's text (MEDIUM_SECTION / LOW_SECTION, AFTER
#         filter-failing-test-findings.sh — a withheld failing-test finding
#         is never scored, so it costs no request).
# stdout: the same text, where every finding the decision model scored
#         carries one extra sub-bullet directly under its line:
#            - 🎯 Decision model: recommends SKIP (invalid) — P(skip) 78% · decision score 32% · …
#         and every finding listed in withhold.txt (filter mode) is removed
#         together with its indented continuation lines.
# report: withheld findings verbatim, plus `<report_file>.count` holding the
#         canonical count — the workflow reads that number and never
#         re-derives it (the LADR-056 lesson: two counts drift).
#
# Inputs come from ai-review-report's lib/recommend-fix-skip.sh
# (recommendations.tsv, header on line 1; withhold.txt, one number per line).
# A missing or empty TSV passes the section through byte-identical.
#
# One-directional by construction: this can only annotate or REMOVE items.
# It never adds a finding the gate did not list, and the Suggested Fixes rule
# already in the prompt ("a fix for something not listed in the Medium or Low
# sections is not applied") covers a withheld finding's suggested fix.
set -euo pipefail

tsv="${1:-}"
withhold="${2:-}"
report_file="${3:-}"

input="$(cat)"

if [ -z "$tsv" ] || [ ! -s "$tsv" ] || [ "$(wc -l < "$tsv" | tr -d ' ')" -lt 2 ]; then
  printf '%s' "$input"
  [ -z "$report_file" ] || { : > "$report_file"; printf '0\n' > "${report_file}.count"; }
  exit 0
fi
[ -n "$withhold" ] && [ -f "$withhold" ] || withhold=/dev/null

withheld_tmp="$(mktemp)"
trap 'rm -f "$withheld_tmp"' EXIT

# `1.`-numbered finding lines are the gate's grammar (LADR-068). An item's
# continuation is every following line that starts with whitespace.
printf '%s' "$input" | awk -F '\t' -v tsv="$tsv" -v wh="$withhold" -v rep="$withheld_tmp" '
  BEGIN {
    FS = "\t"
    while ((getline line < tsv) > 0) {
      if (++r == 1) continue
      split(line, f, "\t")
      # UNCERTAIN (column 17 holds the confidence): the model leans one way
      # but its own confidence is too low to call it a recommendation.
      lean = (f[4] == "fix") ? "FIX" : "SKIP (" f[4] ")"
      if (f[3] == "UNCERTAIN") note = "   - 🎯 Decision model: uncertain, leans " lean " (confidence " f[17] "%)"
      else note = "   - 🎯 Decision model: recommends " ((f[3] == "FIX") ? "FIX" : "SKIP (" f[4] ")")
      sep = " — "
      if (f[5] != "") { note = note sep "P(skip) " f[5] "%"; sep = " · " }
      if (f[6] != "") { note = note sep "decision score " f[6] "%" (f[7] == "yes" ? ", weak quoted evidence" : ""); sep = " · " }
      if (f[8] != "") { note = note sep "rule-allowed " f[8] "%"; sep = " · " }
      if (f[9] != "") { note = note sep "previously skipped " f[9] "%"; sep = " · " }
      if (f[10] != "") { note = note sep "actionability " f[10] " of 2"; sep = " · " }
      if (f[11] == "no") { note = note sep "no diff hunk found" }
      # LADR-098: where the answer came from (column 16, absent before it).
      ann[f[1]] = note ((f[16] == "gate") ? " (advisory, from gate scoring)" : " (advisory)")
    }
    while ((getline line < wh) > 0) { gsub(/[^0-9]/, "", line); if (line != "") drop[line] = 1 }
    FS = " "
  }
  { lines[NR] = $0 }
  END {
    # CommonMark ignores numbers after the first item in an ordered list.
    # Detect a gap among surviving items before printing any of them.
    for (i = 1; i <= NR; i++) {
      if (match(lines[i], /^[0-9]+\. /)) {
        n = substr(lines[i], 1, RLENGTH - 2) + 0
        if (!(n in drop)) {
          if (seen && n != previous + 1) literal = 1
          previous = n
          seen = 1
        }
      }
    }
    for (i = 1; i <= NR; i++) {
      line = lines[i]
      if (match(line, /^[0-9]+\. /)) {
        n = substr(line, 1, RLENGTH - 2)
        dropping = (n in drop)
        if (dropping) { print line > rep; count++; continue }
        if (literal) sub(/^[0-9]+\. /, "- **" n ".** ", line)
        print line
        if (n in ann) print ann[n]
        continue
      }
      if (dropping && line ~ /^[[:space:]]+[^[:space:]]/) { print line > rep; continue }
      dropping = 0
      print line
    }
    printf "%d\n", count > (rep ".count")
  }
'

if [ -n "$report_file" ]; then
  cp "$withheld_tmp" "$report_file"
  cp "${withheld_tmp}.count" "${report_file}.count"
  count="$(tr -dc '0-9' < "${report_file}.count")"
  [ "${count:-0}" -eq 0 ] || echo "Withheld ${count} finding(s) the decision model recommends skipping (LADR-097)." >&2
fi
rm -f "${withheld_tmp}.count"
