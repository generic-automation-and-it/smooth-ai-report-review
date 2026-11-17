#!/bin/bash
# LADR-050: offline per-chunk risk + inferred test-coverage hints, plus the
# opt-in removed-symbol class.
# Usage: printf '%s\0' "${files[@]}" | bash graph-signals-slice.sh [signals.tsv] [removed.tsv]
# Exit 0 = slice, 3 = no rows/insufficient cap, 1 = unusable input/dependency.
# Bash 3.2 compatible. No vendor CLI, git or network; stdout is data only.
#
# removed.tsv (optional, five columns: file_rel, old_line_start, name,
# used_by_total, first_user) renders FIRST, at most three rows and one third of
# the byte cap; risk rows and gaps share what is left. The caller passes it only
# when its flag is on. Absent, empty or unmatched → output byte-identical to the
# single-TSV form. A malformed removed row drops the removed block, never the
# risk/gap block.
set -euo pipefail

TSV="${1:-${GRAPH_SIGNALS_TSV:-ci_temp/graph_review_signals.tsv}}"
REMOVED_TSV="${2:-}"
MAX_BYTES="${OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES:-1024}"
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=1024 ;; esac
# Reject overflow before arithmetic, and use decimal even for leading zeroes.
if [ "${#MAX_BYTES}" -gt 9 ]; then MAX_BYTES=1024; fi
MAX_BYTES=$((10#$MAX_BYTES))
[ "$MAX_BYTES" -gt 0 ] || MAX_BYTES=1024

for dep in awk sort tr mktemp wc cat rm; do
  command -v "$dep" >/dev/null 2>&1 || exit 1
done
[ -f "$TSV" ] && [ -r "$TSV" ] || exit 1
work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

# The rest of the chunk pipeline is line-oriented too. Unsupported control
# characters in a matched TSV path are rejected below, never interpreted.
tr '\0' '\n' > "$work/files" || exit 1
[ -s "$work/files" ] || exit 3

# Validate before rendering anything. Exact lookup preserves spaces and literal
# glob characters; unrelated rows cannot bring another chunk's context along.
if ! LC_ALL=C awk -F'\t' '
  function unsafe(s, lower) {
    lower = tolower(s)
    return s ~ /[`[:cntrl:]]|#[0-9]|🔴|🟠|🟡|🔵/ ||
      lower ~ /issues found|###[[:space:]]*file:/
  }
  FILENAME == ARGV[1] { want[$0] = 1; next }
  $1 in want {
    if (NF != 6 || $1 ~ /^\/|^[A-Za-z]:|(^|\/)\.\.?($|\/)/ ||
        unsafe($1) || $2 !~ /^[1-9][0-9]*$/ || $3 !~ /^[1-9][0-9]*$/ ||
        ($3 + 0) < ($2 + 0) ||
        ($5 != "-" && ($5 !~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/ ||
                       ($5 + 0) < 0 || ($5 + 0) > 1)) ||
        ($6 != "true" && $6 != "false" && $6 != "indirect" &&
         ($6 !~ /^indirect:/ || unsafe(substr($6, 10)) || substr($6, 10) == ""))) exit 1
    name = $4
    # Legacy qualified_name values include an absolute path before ::. Keep
    # ordinary C++/language namespaces intact (Class::method is not a path).
    if (name ~ /^\//) {
      if (name ~ /::/) name = substr(name, index(name, "::") + 2)
      else sub(/^.*\//, "", name)
    }
    if (name == "" || unsafe(name)) exit 1
    print $1 "\t" $2 "\t" $3 "\t" name "\t" $5 "\t" $6
  }
' "$work/files" "$TSV" > "$work/selected"; then
  exit 1
fi

# Removed-symbol block: validated separately so a bad row costs only this block.
: > "$work/removed"
if [ -n "$REMOVED_TSV" ] && [ -f "$REMOVED_TSV" ] && [ -r "$REMOVED_TSV" ]; then
  if LC_ALL=C awk -F'\t' '
    function unsafe(s, lower) {
      lower = tolower(s)
      return s ~ /[`[:cntrl:]]|#[0-9]|🔴|🟠|🟡|🔵/ ||
        lower ~ /issues found|###[[:space:]]*file:/
    }
    FILENAME == ARGV[1] { want[$0] = 1; next }
    $1 in want {
      if (NF != 5 || $1 ~ /^\/|^[A-Za-z]:|(^|\/)\.\.?($|\/)/ || unsafe($1) ||
          $2 !~ /^[1-9][0-9]*$/ || $3 == "" || unsafe($3) || $3 ~ /^\// ||
          $4 !~ /^[1-9][0-9]*$/ || $5 == "" || unsafe($5) || $5 ~ /^\//) exit 1
      if (++n > 3) exit 0
      users = ($4 == 1) ? "1 user" : $4 " users"
      eg = ($5 == "-") ? "" : " (e.g. " $5 ")"
      line[n] = sprintf("`%s:%s` %s — removed by this PR; the graph still records %s%s — verify they were updated or removed.", $1, $2, $3, users, eg)
    }
    END {
      if (n > 3) n = 3
      if (n) {
        print "Removed symbols the graph still records users for:"
        for (i = 1; i <= n; i++) print line[i]
      }
    }
  ' "$work/files" "$REMOVED_TSV" > "$work/removed.all"; then
    removed_cap=$((MAX_BYTES / 3))
    LC_ALL=C awk -v room="$removed_cap" '
      { size = length($0) + 1; if (used + size > room) exit; print; used += size }
    ' "$work/removed.all" > "$work/removed" || : > "$work/removed"
    # A heading with no row under it says nothing.
    [ "$(wc -l < "$work/removed" | tr -d ' ')" -ge 2 ] || : > "$work/removed"
  fi
fi

if [ ! -s "$work/selected" ]; then
  [ -s "$work/removed" ] || exit 3
  cat "$work/removed"
  exit 0
fi
LC_ALL=C sort -t"$(printf '\t')" -k5,5gr "$work/selected" > "$work/rows" || exit 1

if ! awk -F'\t' '
  NR <= 5 {
    printf "`%s:%s` %s", $1, $2, $4
    if ($5 != "-") printf " — risk %s", $5
    if ($6 == "true") printf " — no test coverage detected by graph"
    else if ($6 == "indirect") printf " — no direct test; reached only through a caller"
    else if ($6 ~ /^indirect:/) printf " — no direct test; reached only through a caller (%s)", substr($6, 10)
    printf "\n"
  }
  $6 == "true" && gaps < 3 {
    gaps++
    gap_text = gap_text sprintf("`%s:%s` %s\n", $1, $2, $4)
  }
  END {
    if (gaps) printf "\nChanged functions with no test coverage detected by graph:\n%s", gap_text
  }
' "$work/rows" > "$work/body"; then
  exit 1
fi

# The removed block and its separating blank line come out of the same cap.
removed_bytes=0
if [ -s "$work/removed" ]; then
  removed_bytes=$(( $(wc -c < "$work/removed" | tr -d ' ') + 1 ))
fi
budget=$((MAX_BYTES - removed_bytes))

emit_removed() {
  if [ -s "$work/removed" ]; then
    cat "$work/removed"
    printf '\n'
  fi
}

total="$(wc -c < "$work/body" | tr -d ' ')"
if [ "$total" -le "$budget" ]; then
  emit_removed
  cat "$work/body"
else
  printf '... truncated (graph signals capped at %s bytes)\n' "$MAX_BYTES" > "$work/marker"
  marker_bytes="$(wc -c < "$work/marker" | tr -d ' ')"
  room=$((budget - marker_bytes))
  if [ "$room" -le 0 ]; then
    [ -s "$work/removed" ] || exit 3
    cat "$work/removed"
    exit 0
  fi
  # Whole lines preserve UTF-8, references and risk numbers. LC_ALL=C makes
  # length byte-based on both BSD and GNU awk; the marker is inside the cap.
  LC_ALL=C awk -v room="$room" '
    { size = length($0) + 1; if (used + size > room) exit; print; used += size }
  ' "$work/body" > "$work/out" || exit 1
  if [ ! -s "$work/out" ]; then
    [ -s "$work/removed" ] || exit 3
    cat "$work/removed"
    exit 0
  fi
  emit_removed
  cat "$work/out" "$work/marker"
fi
