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
#  1b. ...but only a COMPLETE, LAST pair is ever stripped — see the anchoring
#     comment above the awk below. A review that merely *quotes* a sentinel must
#     not lose the prose that follows it. This repo reviews its own PRs, six of
#     its own tracked files contain the literal sentinel, and the review model is
#     told to quote the code it flags: the quoting case is not hypothetical here,
#     it is the canonical trigger. Same failure shape as LADR-031 (a marker
#     string quoted into a legitimate review body, text-matched as if it were a
#     control signal), and the same conclusion — a control channel must not be
#     forgeable by review content.
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

# Anchor on the LAST COMPLETE begin..end pair, never the first begin.
#
# The prompt requires the sidecar to be the last thing in the output, so the last
# complete pair is the real block by construction. Anchoring on the first `begin`
# instead makes the channel forgeable by review content: a chunk reviewing one of
# this repo's own files that contains the sentinel — review-in-chunks.sh,
# extract-findings-json.sh, SKILL.md, AGENTS.md, CHANGELOG.md,
# test-merge-findings.sh — need only quote that line in its prose for everything
# after it to be swallowed as "the block". Observed cost when that happens: the
# review is truncated at the quote, the real sidecar is consumed with it and
# fails to parse, and the surviving markdown can fall under the 200-byte
# empty-output floor, turning a clean review into a fail-closed REQUEST_CHANGES
# on a chunk that reviewed fine.
#
# Two discriminators separate a real delimiter from a quoted one, and a single
# real review of this repo produced both shapes at once:
#
#   1. A delimiter is ALONE on its line. The real block always emits the sentinel
#      on its own line; a reviewer quoting it writes it inline mid-sentence
#      ("... the extractor keys on `<!-- ... -->` in review text"). An inline
#      mention is prose and is not a delimiter at all.
#   2. An unterminated `begin` is only honoured when what follows LOOKS like the
#      block — the next non-blank line opens a fence or a JSON value. That is the
#      genuine "model was cut off mid-JSON" case, and stripping it to EOF keeps
#      the wall of JSON out of the posted body. A lone `begin` followed by prose
#      is a quote; stripping there would eat the rest of the review.
#
# Preference order: the last complete pair wins; a later unterminated-but-
# JSON-shaped `begin` beats it, since the prompt puts the real block last.
pair="$(awk -v b="$BEGIN_SENTINEL" -v e="$END_SENTINEL" '
  { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line) }
  line == b { cand = NR; candnext = ""; next }
  cand && line == e { bl = cand; el = NR; cand = 0; next }
  cand && candnext == "" && line != "" { candnext = line }
  END {
    if (cand && cand > bl && (candnext ~ /^```/ || candnext ~ /^[{[]/)) {
      print cand " 0"          # unterminated but JSON-shaped: strip to EOF
    } else if (bl) {
      print bl " " el
    }
  }
' "$chunk_md" 2>/dev/null)"

if [ -z "$pair" ]; then
  echo "  ⚠️ Chunk ${chunk_num}: no findings sidecar delimiter (only a quoted mention) — leaving the review body untouched"
  rm -f "$out_json"
  exit 0
fi

begin_line="${pair%% *}"
end_line="${pair##* }"
# `0` means "unterminated, consume to EOF" — an end line past any real line.
if [ "$end_line" = "0" ]; then
  end_line=$(( $(wc -l < "$chunk_md") + 1 ))
  echo "  ⚠️ Chunk ${chunk_num}: findings sidecar was truncated mid-block — stripping it, continuing without the sidecar"
fi

# Split on the resolved line numbers: everything outside [begin_line, end_line]
# is markdown, everything strictly inside is the block.
awk -v bl="$begin_line" -v el="$end_line" -v md="$tmp_md" -v blk="$tmp_block" '
  NR == bl || NR == el { next }
  NR > bl && NR < el { print > blk; next }
  { print > md }
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
