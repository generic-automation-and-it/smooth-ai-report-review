#!/bin/bash
# run-split-chain.sh — run a two-model opencode chain under ONE total budget,
# split so that a hung primary cannot starve the fallback (LADR-092).
#
# Usage:
#   run-split-chain.sh <label> <total_s> <primary_min_s> <secondary_min_s> \
#                      <primary_model> <secondary_model> -- <prompt-file>
#
# Stdout: the answering model's output, and ONLY on success. Each stage writes
#         to a private temp file first, so a stage killed mid-print can never
#         leave half an answer in front of the next stage's answer.
# Stderr: lib/opencode-with-fallback.sh's stderr from every stage, plus this
#         script's status lines, each prefixed `run-split-chain.sh[<label>]:`
#         so the caller can lift them onto the console (which model, how long,
#         timed out or failed).
# Exit:   0 on success; otherwise the exit code of the LAST stage that ran
#         (124 = killed by `timeout`); 64 on a usage error.
# Env:    everything lib/opencode-with-fallback.sh reads passes straight through
#         (OPENCODE_RUN_CWD, OPENCODE_OUTPUT_SHAPE_CHECK, provider ids, ...).
#
# Why this exists. `lib/opencode-with-fallback.sh` has no clock of its own, so a
# caller that wraps nothing around it waits for a hung model forever, and a
# caller that wraps ONE `timeout` around the whole chain lets a hung primary
# spend the entire budget while the fallback never runs (LADR-066 fixed that for
# grouping, LADR-081 for chunks). The aggregation summary had neither: no bound
# at all, so consumer runs 35969611034 and 35995746041 sat 13+ minutes in a call
# that normally takes one or two.
#
# The split is the LADR-081 mechanism, reused rather than reinvented:
#   - the shares come from lib/split-chunk-budget.sh, with the caller's floors;
#   - stage 1 runs the primary bounded by its share, with NO in-chain fallback
#     when splitting (otherwise one budget funds two attempts at the model
#     stage 2 owns);
#   - stage 2 runs the secondary bounded by what is LEFT of the total
#     (total - elapsed), so a primary that failed fast hands over nearly the
#     whole budget and a primary that timed out hands over exactly the reserve.
#     elapsed + (total - elapsed) = total: the wall-clock bound is the total.
# One deliberate difference from the chunk call site: a DEGENERATE chain (no
# secondary, or secondary == primary — which is what LADR-066's failed
# orchestrator probe produces) is not split at all. The chunk site splits and
# then skips stage 2, idling the reserve; here the one model gets the whole
# budget, because there is nobody to reserve it for.
#
# Bash 3.2 safe (no ${v,,}, no mapfile): local-review.sh reaches the caller.
set -uo pipefail

_rsc_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 8 ]; then
  echo "run-split-chain.sh: usage: <label> <total_s> <primary_min_s> <secondary_min_s> <primary> <secondary> -- <prompt-file>" >&2
  exit 64
fi
_rsc_label="$1"; _rsc_total="$2"; _rsc_pmin="$3"; _rsc_smin="$4"
_rsc_primary="$5"; _rsc_secondary="$6"; shift 6
[ "${1:-}" = "--" ] && shift
_rsc_prompt="${1:-}"

_rsc_log() { printf 'run-split-chain.sh[%s]: %s\n' "$_rsc_label" "$*" >&2; }

# `timeout 0s` imposes NO limit, and an empty duration is a usage error that
# would read as a model failure. Refuse rather than run unbounded — the caller
# validated this value, so reaching here is a bug at the call site.
if ! [[ "$_rsc_total" =~ ^[1-9][0-9]*$ ]]; then
  _rsc_log "total budget '${_rsc_total}' is not a positive integer — refusing to run unbounded"
  exit 64
fi
if [ -z "$_rsc_primary" ]; then
  _rsc_log "no primary model given"
  exit 64
fi

if [ -z "$_rsc_secondary" ] || [ "$_rsc_secondary" = "$_rsc_primary" ]; then
  _rsc_secondary=""
  _rsc_p="$_rsc_total"; _rsc_s=0
else
  read -r _rsc_p _rsc_s \
    <<< "$(bash "${_rsc_lib_dir}/split-chunk-budget.sh" "$_rsc_total" "$_rsc_pmin" "$_rsc_smin")"
  # The lib prints "0 0" on junk rather than guessing; keep the validated total.
  if ! [[ "${_rsc_p:-}" =~ ^[1-9][0-9]*$ ]] || ! [[ "${_rsc_s:-}" =~ ^[0-9]+$ ]]; then
    _rsc_p="$_rsc_total"; _rsc_s=0
  fi
fi

if [ "$_rsc_s" -gt 0 ]; then
  _rsc_stage1_fb=""
  _rsc_log "budget ${_rsc_total}s split: ${_rsc_p}s for ${_rsc_primary}, then what is left (at least ${_rsc_s}s) for ${_rsc_secondary}"
elif [ -n "$_rsc_secondary" ]; then
  _rsc_stage1_fb="$_rsc_secondary"
  _rsc_log "budget ${_rsc_total}s too small to split (floors ${_rsc_pmin}s + ${_rsc_smin}s): one ${_rsc_total}s bound around ${_rsc_primary} then ${_rsc_secondary}"
else
  _rsc_stage1_fb=""
  _rsc_log "budget ${_rsc_total}s, single model ${_rsc_primary} (no distinct fallback to reserve time for)"
fi

_rsc_out="$(mktemp)"
trap 'rm -f "$_rsc_out"' EXIT

_rsc_describe() { # _rsc_describe <rc> <elapsed> <limit> <what>
  if [ "$1" -eq 124 ]; then
    _rsc_log "$4 timed out after ${2}s (limit ${3}s)"
  else
    _rsc_log "$4 failed (rc $1) after ${2}s"
  fi
}

_rsc_started=$(date +%s)
timeout "${_rsc_p}s" bash "${_rsc_lib_dir}/opencode-with-fallback.sh" \
  "$_rsc_primary" "$_rsc_stage1_fb" "" -- "$_rsc_prompt" > "$_rsc_out"
_rsc_rc=$?
_rsc_elapsed=$(( $(date +%s) - _rsc_started ))
if [ "$_rsc_rc" -eq 0 ]; then
  cat "$_rsc_out"
  _rsc_log "${_rsc_primary}${_rsc_stage1_fb:+ (or in-chain ${_rsc_stage1_fb})} answered in ${_rsc_elapsed}s"
  exit 0
fi
_rsc_describe "$_rsc_rc" "$_rsc_elapsed" "$_rsc_p" \
  "stage 1 (${_rsc_primary}${_rsc_stage1_fb:+ then ${_rsc_stage1_fb}})"

if [ "$_rsc_s" -gt 0 ]; then
  _rsc_remaining=$(( _rsc_total - _rsc_elapsed ))
  if [ "$_rsc_remaining" -le 0 ]; then
    _rsc_log "no time left for ${_rsc_secondary} (${_rsc_elapsed}s of ${_rsc_total}s spent)"
    exit "$_rsc_rc"
  fi
  _rsc_log "handing the remaining ${_rsc_remaining}s to ${_rsc_secondary}"
  _rsc_started2=$(date +%s)
  timeout "${_rsc_remaining}s" bash "${_rsc_lib_dir}/opencode-with-fallback.sh" \
    "$_rsc_secondary" "" "" -- "$_rsc_prompt" > "$_rsc_out"
  _rsc_rc=$?
  _rsc_elapsed2=$(( $(date +%s) - _rsc_started2 ))
  if [ "$_rsc_rc" -eq 0 ]; then
    cat "$_rsc_out"
    _rsc_log "rescued by ${_rsc_secondary} in ${_rsc_elapsed2}s"
    exit 0
  fi
  _rsc_describe "$_rsc_rc" "$_rsc_elapsed2" "$_rsc_remaining" "stage 2 (${_rsc_secondary})"
fi
exit "$_rsc_rc"
