#!/bin/bash
# extract-findings-json.sh — pull the LADR-055 structured-findings sidecar out of
# a chunk review, and strip it from the markdown so the posted body is unchanged.
#
# Usage: extract-findings-json.sh <chunk_md> <chunk_num> <out_json>
#
# The chunk prompt asks the model to append, after the human-readable review:
#
#   <!-- FINDINGS_JSON_BEGIN -->
#   ```json
#   { "chunk": N, "findings": [...], "residual_risks": [], "testing_gaps": [] }
#   ```
#   <!-- FINDINGS_JSON_END -->
#
# Contract, in priority order:
#
#  1. The markdown a human reads must be byte-identical to what it would have
#     been before this feature. That means the sentinel range is stripped
#     INCLUSIVE, always — whether the JSON inside it parsed or not. A malformed
#     block is our problem, not the PR author's; leaving it in would post a wall
#     of JSON to the PR. The sentinels are HTML comments so even a leaked one
#     renders invisibly rather than corrupting the body.
#  2. The sidecar is best-effort and NEVER a chunk failure. Missing block,
#     truncated block, malformed JSON, wrong top-level shape — every one of these
#     logs a warning, removes any partial output, and exits 0. LADR-031's
#     `chunk_<n>.failed` flag file is the ONLY chunk-failure signal and it means
#     something else entirely; this script must never write one, and callers must
#     never treat its warnings as a failure condition.
#  3. `chunk` is stamped deterministically from the caller's chunk number, not
#     trusted from the model. The dedup axis must be right even when the model
#     miscounts, and normalising here means the merge helper never has to
#     reconcile a self-reported index against the filename it came from.
#
# jq only — no Python. The merge step (merge-findings.sh) needs an interpreter
# and degrades when there isn't one; extraction must still happen in that case so
# the sidecar is available to future consumers and the markdown is still clean.
set -uo pipefail

chunk_md="${1:-}"
chunk_num="${2:-}"
out_json="${3:-}"

if [ -z "$chunk_md" ] || [ -z "$chunk_num" ] || [ -z "$out_json" ]; then
  echo "usage: extract-findings-json.sh <chunk_md> <chunk_num> <out_json>" >&2
  exit 0
fi

[ -f "$chunk_md" ] || exit 0

BEGIN_SENTINEL='<!-- FINDINGS_JSON_BEGIN -->'
END_SENTINEL='<!-- FINDINGS_JSON_END -->'

# Nothing to do when the model did not emit a sidecar. This is the expected path
# for any model that ignores the instruction, and it is not worth a warning —
# the review is complete and correct without it.
if ! grep -qF "$BEGIN_SENTINEL" "$chunk_md" 2>/dev/null; then
  exit 0
fi

tmp_block="${out_json}.block.tmp"
tmp_md="${chunk_md}.stripped.tmp"

# Split the file in one awk pass: everything outside the sentinel range goes to
# the stripped markdown, everything strictly inside goes to the block. An
# unterminated block (model output cut off mid-JSON) consumes to EOF — the
# remainder is JSON, not review prose, so keeping it would be noise either way.
awk -v b="$BEGIN_SENTINEL" -v e="$END_SENTINEL" -v md="$tmp_md" -v blk="$tmp_block" '
  index($0, b) { inblock = 1; seen = 1; next }
  inblock && index($0, e) { inblock = 0; next }
  inblock { print > blk; next }
  { print > md }
  END { if (seen && inblock) print "unterminated" > "/dev/stderr" }
' "$chunk_md" 2>/dev/null

# awk only creates an output file once it writes to it; make sure both exist.
[ -f "$tmp_md" ] || : > "$tmp_md"
[ -f "$tmp_block" ] || : > "$tmp_block"

# Strip the markdown regardless of what happens to the JSON below (contract 1).
mv "$tmp_md" "$chunk_md" 2>/dev/null || rm -f "$tmp_md"

# Peel the ```json ... ``` fence off the extracted block. The fence is part of
# the requested shape, but a model that emits bare JSON between the sentinels is
# just as usable, so both are accepted.
payload="$(sed -e '/^[[:space:]]*```/d' "$tmp_block" 2>/dev/null)"
rm -f "$tmp_block"

if [ -z "${payload//[[:space:]]/}" ]; then
  echo "  ⚠️ Chunk ${chunk_num}: findings sidecar was empty — continuing without it"
  rm -f "$out_json"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  ⚠️ Chunk ${chunk_num}: jq unavailable — findings sidecar discarded"
  rm -f "$out_json"
  exit 0
fi

# Validate the top-level shape and stamp the authoritative chunk number. Field-
# level validation is the merge helper's job (it counts malformed findings rather
# than dropping the whole document), so this only rejects payloads that are not a
# findings document at all.
if printf '%s\n' "$payload" | jq -e '
      type == "object" and (.findings | type) == "array"
    ' >/dev/null 2>&1; then
  if printf '%s\n' "$payload" | jq --argjson n "$chunk_num" '
        {
          chunk: $n,
          findings: .findings,
          residual_risks: (if (.residual_risks | type) == "array" then .residual_risks else [] end),
          testing_gaps: (if (.testing_gaps | type) == "array" then .testing_gaps else [] end)
        }
      ' > "$out_json" 2>/dev/null; then
    finding_count="$(jq '.findings | length' "$out_json" 2>/dev/null || echo '?')"
    echo "  🧩 Chunk ${chunk_num}: findings sidecar extracted (${finding_count} finding(s))"
    exit 0
  fi
fi

echo "  ⚠️ Chunk ${chunk_num}: findings sidecar was not valid JSON — continuing without it"
rm -f "$out_json"
exit 0
