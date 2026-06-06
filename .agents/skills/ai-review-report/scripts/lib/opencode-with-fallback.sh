#!/bin/bash
# Usage: opencode-with-fallback.sh <primary> <fallback1> <fallback2> -- <prompt-file>
#
# Replaces the previous `gemini -m <model> --yolo < prompt-file` pattern.
# Invokes opencode for each model in turn, returning on the first success.
# Callers pass an explicit chain (LADR-002 / LADR-023):
#   - chunk review:  PRIMARY_REVIEW   SECONDARY_REVIEW   ""
#   - orchestrator:  ORCHESTRATOR     <resolved review model>   ""
# An empty model slot is skipped, so a two-tier chain just leaves fb2 empty.
#
# The provider is selected by OPENCODE_PROVIDER (GEMINI|COPILOT|OPENAI) and
# resolved to its opencode provider-id by lib/resolve-provider.sh, which exports
# OPENCODE_PROVIDER_ID (gemini / github-copilot / openai). This script
# reads that id below; it defaults to gemini when unset so a bare
# invocation keeps the historical Gemini behavior. Credentials are read by
# opencode itself via the {env:OPENCODE_<P>_*} placeholders in opencode.json.
#
# Stdout: opencode review output. Stderr: passthrough.

set -e

primary="$1"; fb1="$2"; fb2="$3"; shift 3
[ "$1" = "--" ] && shift
prompt_file="$1"; shift

if [ -z "$prompt_file" ] || [ ! -f "$prompt_file" ]; then
  echo "opencode-with-fallback.sh: prompt file missing or not readable: ${prompt_file:-<empty>}" >&2
  exit 64
fi

PROVIDER="${OPENCODE_PROVIDER_ID:-gemini}"

run_opencode() {
  # No --agent flag: we let opencode use its DEFAULT `build` agent but override
  #   its model via --model (so it runs on Gemini, not build's pinned model).
  #   The default agent provides read/grep tools, so the prompt's read_file
  #   instructions work — the model reads the listed context files. opencode.json
  #   sets `permission.external_directory: allow` (LADR-025), the headless
  #   equivalent of the old gemini-cli --yolo: without it opencode auto-rejects
  #   reads of in-repo dot-paths (.github/*, .docs/*, .agents/rules-scoped/*) in
  #   non-interactive `run` mode, which silently empties the chunk.
  # Prompt is fed via stdin (not "$(cat …)" argv expansion) so large chunks
  #   never hit ARG_MAX; matches the original `gemini < file` call shape.
  # --log-level WARN: keeps stdout clean for the legacy parser surface.
  #   On failure, review-in-chunks.sh's empty-output detector dumps the
  #   chunk file + stderr so diagnostics surface where it matters. To
  #   debug a stuck/flaky chunk locally, re-run with --log-level INFO
  #   --print-logs.
  # --format default: human-readable markdown matching the legacy parser surface
  #   (sed/grep on DETAILED_SECTION_MARKER and per-priority emoji lines).
  opencode run \
    --model "${PROVIDER}/$1" \
    --format default \
    --log-level WARN \
    < "$prompt_file"
}

try_run() {
  local model="$1"
  [ -z "$model" ] && return 1
  run_opencode "$model"
}

try_run "$primary" \
  || try_run "$fb1" \
  || try_run "$fb2"
