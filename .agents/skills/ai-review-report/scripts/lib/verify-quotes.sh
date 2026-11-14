#!/bin/bash
# verify-quotes.sh — check each merged finding's quoted line against the tree at
# the reviewed revision (LADR-119).
#
# Usage: verify-quotes.sh <merged_json> <report_json> <source_rev>
#
# Called by lib/merge-findings.sh after the merge, so `merge-findings.py` stays a
# pure stdin→stdout module and every filesystem/git read lives in the wrapper
# layer (LADR-055, R6).
#
# A finding anchored at 75 or 100 claims a verbatim motivating line in
# `first_evidence`. merge-findings.py enforces only that the field is non-blank;
# this checks that the line actually exists. A miss demotes confidence to 50 and
# never drops the finding: a demoted non-critical finding is moved to the
# suppressed set (the existing confidence gate), while a Critical is exempt and
# stays in `findings` exactly as merge-findings.py treats it.
#
# Fail-open: every condition that is not a definite miss is a skip —
# unknown revision, an unrecognisable prefix, an absent named file, a multi-line
# or very short quote, a pre-existing finding, a git error or timeout. A skip
# never changes an anchor.
#
# Exit: 0 always. Best-effort: a failure leaves the merged document untouched.
set -uo pipefail

merged="${1:-}"
report="${2:-}"
rev="${3:-}"

[ -n "$merged" ] && [ -s "$merged" ] || exit 0
[ -n "$report" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e '.status == "complete"' "$merged" >/dev/null 2>&1 || exit 0

# Unknown revision: nothing can be verified, so nothing is demoted and no report
# is written (the renderer emits no Coverage line, leaving the body as it is).
[ -n "$rev" ] || exit 0
git rev-parse --verify --quiet "${rev}^{commit}" >/dev/null 2>&1 || exit 0

WORK_DIR="$(mktemp -d 2>/dev/null || echo "${report}.work")"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

git_bounded() {
  if command -v timeout >/dev/null 2>&1; then timeout 5 git "$@"; else git "$@"; fi
}

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# contains_line <content> <quote> — 0 when some line of <content>, trimmed of
# surrounding whitespace, equals <quote> exactly. The quote is DATA, not an awk
# -v value: `-v` interprets backslash escapes (BSD awk also rejects literal
# newlines), so a fabricated quote carrying `\\` would collapse to `\` and match
# a source line it does not equal. ENVIRON passes the string through untouched —
# the same reason renumber-suggested-fixes.sh reads its mapping from a file.
contains_line() {
  # Trailing `\r` is trimmed too: a CRLF source line would otherwise never equal
  # a quote whose own surrounding whitespace was already stripped.
  Q="$2" awk '
    { t=$0; sub(/^[ \t\r]+/,"",t); sub(/[ \t\r]+$/,"",t); if (t == ENVIRON["Q"]) { found=1; exit } }
    END { exit(found ? 0 : 1) }
  ' <<< "$1"
}

# One merged-finding candidate per line: index, file, first_evidence.
jq -c '
  .findings | to_entries[]
  | select((.value.confidence // 0) >= 75)
  | select((.value.pre_existing // false) | not)
  | select(((.value.first_evidence // "") | length) > 0)
  | { idx: .key, file: (.value.file // ""), ev: .value.first_evidence }
' "$merged" > "${WORK_DIR}/candidates.jsonl" 2>/dev/null || exit 0
[ -s "${WORK_DIR}/candidates.jsonl" ] || exit 0

: > "${WORK_DIR}/entries.jsonl"
demoted_idxs=""
demoted=0
elsewhere=0
skipped=0

record() { # result reason extra-json
  jq -nc --argjson idx "$1" --arg file "$2" --arg result "$3" --arg reason "$4" --argjson extra "${5:-null}" \
    '{index:$idx, file:$file, result:$result, reason:$reason} + (if $extra == null then {} else $extra end)' \
    >> "${WORK_DIR}/entries.jsonl"
}

while IFS= read -r row; do
  idx="$(jq -r '.idx' <<< "$row")"
  ffile="$(jq -r '.file' <<< "$row")"
  ev="$(jq -r '.ev' <<< "$row")"

  # `file:line -- text` / `file:line - text` / `file:line: text`. Bash ERE has no
  # non-capturing groups. An unrecognisable prefix is a skip, not a demotion.
  if [[ "$ev" =~ ^(.+):([0-9]+(-[0-9]+)?)[[:space:]]*(--|-|:)[[:space:]]*(.+)$ ]]; then
    qfile="${BASH_REMATCH[1]}"
    quote="${BASH_REMATCH[5]}"
  else
    skipped=$((skipped + 1)); record "$idx" "$ffile" "skip" "unrecognised_prefix"; continue
  fi

  case "$quote" in
    *$'\n'*) skipped=$((skipped + 1)); record "$idx" "$qfile" "skip" "multiline_quote"; continue ;;
  esac

  quote="$(trim "$quote")"
  if [ "${#quote}" -ge 2 ] && [ "${quote:0:1}" = '`' ] && [ "${quote: -1}" = '`' ]; then
    quote="${quote:1:${#quote}-2}"
    quote="$(trim "$quote")"
  fi

  tokens="$(printf '%s' "$quote" | wc -w | tr -d ' ')"
  visible="$(printf '%s' "$quote" | tr -d '[:space:]')"
  if [ "$tokens" -lt 3 ] || [ "${#visible}" -lt 12 ]; then
    skipped=$((skipped + 1)); record "$idx" "$qfile" "skip" "short_quote"; continue
  fi

  # The file named in the quote wins over finding.file: an omission finding
  # legitimately points at a different file than the one it is filed against.
  if ! git cat-file -e "${rev}:${qfile}" 2>/dev/null; then
    skipped=$((skipped + 1)); record "$idx" "$qfile" "skip" "absent_file"; continue
  fi

  content=""
  show_rc=0
  content="$(git_bounded show "${rev}:${qfile}" 2>/dev/null)" || show_rc=$?
  if [ "$show_rc" -ne 0 ]; then
    skipped=$((skipped + 1)); record "$idx" "$qfile" "skip" "git_error"; continue
  fi

  if contains_line "$content" "$quote"; then
    record "$idx" "$qfile" "verified" "quote_found"
    continue
  fi

  # Second look, repo-wide at the same revision, bounded. A quote that exists in
  # another file keeps its anchor: the finding may simply name the wrong file,
  # which is not evidence that the quote was invented.
  #
  # The exit status is load-bearing. grep uses 1 for "no match" and 2+ for an
  # error; a timeout adds 124. Only 1 is a miss — treating any non-zero status as
  # a miss would demote a real finding whenever git itself failed, which is the
  # one outcome the fail-open rule exists to prevent.
  hits=""
  grep_rc=0
  hits="$(git_bounded grep -l -F -e "$quote" "$rev" -- . 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 1 ]; then
    demoted=$((demoted + 1))
    demoted_idxs="${demoted_idxs}${demoted_idxs:+,}${idx}"
    record "$idx" "$qfile" "demoted" "quote_not_found"
    continue
  fi
  if [ "$grep_rc" -ne 0 ]; then
    skipped=$((skipped + 1)); record "$idx" "$qfile" "skip" "git_error"; continue
  fi

  # `git grep` only narrows the candidates; the confirmation is the SAME
  # trimmed-line equality as the named file. A substring hit — the quote buried
  # in a comment or inside a longer line — is not the line the finding claims,
  # and accepting it would keep a fabricated quote blocking. Bounded to the
  # first twenty candidate files and five confirming ones.
  confirming=""
  confirmed=0
  # A search that could not examine every candidate is inconclusive, never a
  # miss: a failed candidate read, or a candidate list longer than the cap,
  # means the quote may exist in a file that was never checked. Demoting there
  # would suppress a genuine finding — the fail-open rule's exact failure mode.
  inconclusive=0
  cand_total="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  [ "$cand_total" -gt 20 ] && inconclusive=1
  while IFS= read -r cand; do
    cand="${cand#"${rev}:"}"
    [ -n "$cand" ] || continue
    [ "$cand" = "$qfile" ] && continue
    cand_rc=0
    cand_content="$(git_bounded show "${rev}:${cand}" 2>/dev/null)" || cand_rc=$?
    if [ "$cand_rc" -ne 0 ]; then inconclusive=1; continue; fi
    if contains_line "$cand_content" "$quote"; then
      confirming="${confirming}${confirming:+$'\n'}${cand}"
      confirmed=$((confirmed + 1))
      [ "$confirmed" -ge 5 ] && break
    fi
  done <<< "$(printf '%s\n' "$hits" | head -n 20)"

  if [ -n "$confirming" ]; then
    elsewhere=$((elsewhere + 1))
    record "$idx" "$qfile" "found_elsewhere" "quote_in_other_file" \
      "$(printf '%s\n' "$confirming" | jq -R . | jq -s '{found_in: .}')"
    continue
  fi
  if [ "$inconclusive" -eq 1 ]; then
    skipped=$((skipped + 1)); record "$idx" "$qfile" "skip" "incomplete_search"; continue
  fi

  demoted=$((demoted + 1))
  demoted_idxs="${demoted_idxs}${demoted_idxs:+,}${idx}"
  record "$idx" "$qfile" "demoted" "quote_not_found"
done < "${WORK_DIR}/candidates.jsonl"

if [ "$demoted" -gt 0 ]; then
  demote_json="[${demoted_idxs}]"
  tmp_out="${merged}.qv.tmp"
  if jq --argjson demote "$demote_json" '
        def is_demoted($k): ($demote | index($k)) != null;
        (.findings | to_entries) as $fe
        | ($fe | map(select(is_demoted(.key) and .value.severity != "critical"))) as $moved
        | .findings = ($fe | map(
            if is_demoted(.key) and .value.severity != "critical" then empty
            elif is_demoted(.key) then (.value | .confidence = 50)
            else .value end))
        # LADR-068: the renderer prints the stored `#`, and its ordered-list form
        # is safe only while the sequence is contiguous — renumber after a
        # removal exactly as merge-findings.py numbers after suppression.
        | .findings = (.findings | to_entries | map(.value + {"#": (.key + 1)}))
        | .suppressed_findings = ((.suppressed_findings // []) + ($moved | map(.value | .confidence = 50)))
        | (.suppressed_by_confidence // {}) as $s
        | .suppressed_by_confidence = ($s + {"50": (($s["50"] // 0) + ($moved | length))})
      ' "$merged" > "$tmp_out" 2>/dev/null && [ -s "$tmp_out" ]; then
    mv "$tmp_out" "$merged"
  else
    rm -f "$tmp_out"
  fi
fi

jq -n \
  --arg revision "$rev" \
  --argjson demoted "$demoted" \
  --argjson found_elsewhere "$elsewhere" \
  --argjson skipped "$skipped" \
  --slurpfile entries "${WORK_DIR}/entries.jsonl" \
  '{revision:$revision, demoted:$demoted, found_elsewhere:$found_elsewhere, skipped:$skipped, findings:$entries}' \
  > "$report" 2>/dev/null || true

echo "🔎 Quote verification: ${demoted} demoted, ${elsewhere} found elsewhere, ${skipped} skipped" >&2
exit 0
