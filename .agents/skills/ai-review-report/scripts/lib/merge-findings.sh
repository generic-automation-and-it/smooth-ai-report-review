#!/bin/bash
# merge-findings.sh — collect every chunk's structured-findings sidecar and merge
# them into one deterministic document (LADR-055).
#
# Usage: merge-findings.sh <reviews_dir> <out_json>
#   reviews_dir : directory holding chunk_<n>.findings.json (normally ci_temp/reviews)
#   out_json    : where to write the merged document (normally ci_temp/findings.merged.json)
#
# Exit codes:
#   0  merged document written
#   1  nothing to merge, or the merge could not run — caller continues on the
#      pre-LADR-055 path with no merged document. This is a normal outcome, not
#      an error: every model that ignores the sidecar instruction lands here.
#
# This wrapper owns the two things merge-findings.py deliberately does not:
# interpreter resolution and filesystem access. Keeping both here means there is
# exactly one place in the repo that knows how to find a Python, and the merge
# algorithm itself stays a pure stdin→stdout function that a test can drive with
# a heredoc.
#
# Python is a soft dependency. The gate runs on ubuntu-latest where python3 is
# always present, but the local-job and npm-in-CI packagings guarantee nothing,
# so an absent interpreter degrades to "no merged document" exactly like an
# absent sidecar — same as lib/build-code-graph.sh and lib/install-rtk.sh treat
# their own tools.
set -uo pipefail

reviews_dir="${1:-ci_temp/reviews}"
out_json="${2:-ci_temp/findings.merged.json}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_PY="$LIB_DIR/merge-findings.py"

[ -d "$reviews_dir" ] || exit 1

# Collect sidecars in numeric chunk order. Ordering does not change the merged
# output (every sort key downstream is total) but it keeps the intermediate
# array stable, which makes a failed run reproducible from the logs.
#
# A temp file rather than `< <(...)`: process substitution needs /dev/fd, which
# is not guaranteed on every shell this repo's scripts run under (Git Bash, and
# some container images mount it incompletely), and its absence fails silently
# enough to look like "no sidecars were produced".
sidecars=()
_list_tmp="$(mktemp 2>/dev/null || echo "${out_json}.list.tmp")"
find "$reviews_dir" -maxdepth 1 -name 'chunk_*.findings.json' -print 2>/dev/null \
  | sort -V > "$_list_tmp" 2>/dev/null || true
while IFS= read -r f; do
  [ -s "$f" ] && sidecars+=("$f")
done < "$_list_tmp"
rm -f "$_list_tmp"

if [ "${#sidecars[@]}" -eq 0 ]; then
  echo "ℹ️  No structured findings sidecars found — skipping merge (LADR-055)"
  exit 1
fi

if [ ! -f "$MERGE_PY" ]; then
  echo "⚠️  merge-findings.py not found at ${MERGE_PY} — skipping merge"
  exit 1
fi

# Defensive interpreter resolution, in the order most likely to exist on a
# GitHub-hosted runner, a developer's macOS shell, and Git Bash on Windows.
PY_BIN=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1; then
    # `py` is the Windows launcher and needs -3; verify the candidate actually
    # runs before committing to it, so a stub on PATH cannot silently win.
    if [ "$candidate" = "py" ]; then
      if py -3 -c 'import sys' >/dev/null 2>&1; then
        PY_BIN="py -3"
        break
      fi
      continue
    fi
    if "$candidate" -c 'import sys' >/dev/null 2>&1; then
      PY_BIN="$candidate"
      break
    fi
  fi
done

if [ -z "$PY_BIN" ]; then
  echo "⚠️  No Python interpreter (python3/python/py) — skipping findings merge (LADR-055)"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  jq unavailable — skipping findings merge (LADR-055)"
  exit 1
fi

tmp_in="${out_json}.in.tmp"
tmp_out="${out_json}.out.tmp"

# `jq -s` slurps the per-chunk documents into the array merge-findings.py reads.
# A single unparseable sidecar would fail the whole slurp, so feed them one at a
# time and drop the bad ones here — the merge helper counts malformed *findings*,
# but a malformed *document* never reaches it.
: > "$tmp_in"
kept=0
{
  printf '[\n'
  for f in "${sidecars[@]}"; do
    if jq -e . "$f" >/dev/null 2>&1; then
      [ "$kept" -gt 0 ] && printf ',\n'
      jq -c . "$f"
      kept=$((kept + 1))
    else
      echo "⚠️  Skipping unparseable sidecar: $f" >&2
    fi
  done
  printf '\n]\n'
} > "$tmp_in"

if [ "$kept" -eq 0 ]; then
  echo "⚠️  No parseable findings sidecars — skipping merge (LADR-055)"
  rm -f "$tmp_in"
  exit 1
fi

if ! $PY_BIN "$MERGE_PY" < "$tmp_in" > "$tmp_out" 2>"${out_json}.err.tmp"; then
  echo "⚠️  Findings merge failed — continuing without merged findings (LADR-055)"
  [ -s "${out_json}.err.tmp" ] && sed -n '1,20p' "${out_json}.err.tmp"
  rm -f "$tmp_in" "$tmp_out" "${out_json}.err.tmp"
  exit 1
fi
rm -f "${out_json}.err.tmp"

if ! jq -e '.status == "complete"' "$tmp_out" >/dev/null 2>&1; then
  echo "⚠️  Findings merge produced no usable document — continuing without it (LADR-055)"
  rm -f "$tmp_in" "$tmp_out"
  exit 1
fi

mv "$tmp_out" "$out_json"
rm -f "$tmp_in"

echo "✅ Merged findings from ${kept} chunk sidecar(s) → ${out_json}"
jq -r '
  "   findings: \(.findings | length)"
  + " | suppressed: \(.suppressed_findings | length)"
  + " | pre-existing: \(.pre_existing_findings | length)"
  + " | merged duplicates: \(.merged_duplicates)"
  + " | demoted (no quote): \(.demoted_no_quote)"
  + " | malformed: \(.malformed_findings)"
' "$out_json" 2>/dev/null || true
# The same rejection causes the posted Coverage block now carries, in the run
# log — uncapped here, because a maintainer reading CI output wants every cause,
# and no truncation limit applies. `// {}` keeps a pre-reasons document readable.
jq -r '
  ( if ((.malformed_reasons // {}) | length) > 0 then
      "   causes (findings): "
      + ([ .malformed_reasons | to_entries | sort_by(-.value, .key) | .[]
           | "\(.key) ×\(.value)" ] | join(" | "))
    else empty end ),
  ( if ((.malformed_return_reasons // {}) | length) > 0 then
      "   causes (chunk documents): "
      + ([ .malformed_return_reasons | to_entries | sort_by(-.value, .key) | .[]
           | "\(.key) ×\(.value)" ] | join(" | "))
    else empty end )
' "$out_json" 2>/dev/null || true
exit 0
