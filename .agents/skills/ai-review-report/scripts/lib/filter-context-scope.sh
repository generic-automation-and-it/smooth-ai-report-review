#!/bin/bash
# filter-context-scope.sh — drop context files whose declared scope excludes
# this chunk.
#
# Usage:  filter-context-scope.sh <chunk-files-list> <candidates-list> [<mandatory-list>]
# Stdout: the candidates that apply, one path per line.
#
# Interpreter resolution + fail-open live here; the matching itself is in
# lib/context-scope-filter.py (same split as merge-findings.sh / .py).
#
# Python is a SOFT dependency, exactly as it is for LADR-055's merge. With no
# interpreter this prints the candidate list unchanged, which is the behaviour
# that shipped before scope filtering existed — a review with a few extra rule
# paths, not a review missing the rules it needed.
set -uo pipefail

_chunk_files="${1:-}"
_candidates="${2:-}"
_mandatory="${3:-}"

[ -f "$_candidates" ] || exit 0
if [ ! -s "$_candidates" ]; then exit 0; fi

_passthrough() { cat "$_candidates"; }

_py=""
for _c in python3 python py; do
  if command -v "$_c" >/dev/null 2>&1; then _py="$_c"; break; fi
done
if [ -z "$_py" ]; then
  echo "⚠️  No Python interpreter — skipping context scope filtering (all context files kept)." >&2
  _passthrough
  exit 0
fi

_script="$(dirname "${BASH_SOURCE[0]}")/context-scope-filter.py"
if [ ! -f "$_script" ]; then
  echo "⚠️  context-scope-filter.py missing — keeping all context files." >&2
  _passthrough
  exit 0
fi

_json="$(
  CHUNK="$_chunk_files" CANDS="$_candidates" MAND="$_mandatory" "$_py" - <<'PYJSON'
import json, os
def lines(p):
    if not p or not os.path.isfile(p):
        return []
    with open(p, encoding="utf-8", errors="replace") as fh:
        return [l.strip() for l in fh if l.strip()]
print(json.dumps({
    "chunk_files": lines(os.environ.get("CHUNK")),
    "candidates":  lines(os.environ.get("CANDS")),
    "mandatory":   lines(os.environ.get("MAND")),
}))
PYJSON
)" || { echo "⚠️  Could not build scope-filter input — keeping all context files." >&2; _passthrough; exit 0; }

if ! printf '%s' "$_json" | "$_py" "$_script"; then
  echo "⚠️  Context scope filtering failed — keeping all context files." >&2
  _passthrough
fi
