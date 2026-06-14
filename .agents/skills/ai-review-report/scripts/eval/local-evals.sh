#!/bin/bash
# local-evals.sh — local entrypoint for the chunk-review LLM eval harness.
#
# Mirrors local-review.sh's environment bootstrap so the eval runs against the
# SAME provider/transport as CI, with no manual setup:
#   1. harvests every provider's credentials from the shell rc files (the skill
#      runs scripts in a non-interactive shell that does not source ~/.zshrc);
#   2. provides macOS GNU-tool shims (`timeout` — review-in-chunks.sh uses it);
#   3. sets the model chain (primary = --model) and exports OPENCODE_REVIEW_REPORT_PROVIDER;
#   4. hands off to run-evals.sh, which resolves+validates the provider, installs
#      the managed opencode.json, health-checks opencode, and runs the corpus.
#
# *** MAKES REAL, PAID MODEL CALLS. ***
#
# Usage:
#   ./local-evals.sh [--provider P] [--model M] [--samples N] [--recall-threshold N] [--filter SUBSTR]
#
#   --provider P           GEMINI (default) | COPILOT | OPENAI |
#                          OPENCODE-GO-OPENAI | OPENCODE-GO-ANTHROPIC | OPEN_ROUTER
#                          (or set OPENCODE_REVIEW_REPORT_PROVIDER)
#   --model M              chunk-review model under eval (default: the
#                          OPENCODE_REVIEW_REPORT_MODEL_PRIMARY env/Variable, else
#                          gemini-3.1-pro-preview). For non-GEMINI providers also
#                          export OPENCODE_REVIEW_REPORT_MODEL_SECONDARY /
#                          OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR (non-gemini ids)
#                          — else they default to --model; lib/resolve-provider.sh
#                          fails fast on a gemini id under a non-GEMINI provider.
#   --samples N            runs per fixture (default 1; >1 = precision worst-case, recall majority)
#   --recall-threshold N   min must-catch catch-rate %% to pass (default 80)
#   --filter SUBSTR        only run fixtures whose id contains SUBSTR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENCODE_REVIEW_REPORT_PROVIDER="${OPENCODE_REVIEW_REPORT_PROVIDER:-GEMINI}"
OPENCODE_MODEL="${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-gemini-3.1-pro-preview}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)         OPENCODE_REVIEW_REPORT_PROVIDER="$2"; shift 2 ;;
    --model)            OPENCODE_MODEL="$2"; shift 2 ;;
    --samples)          export EVAL_SAMPLES="$2"; shift 2 ;;
    --recall-threshold) export EVAL_RECALL_THRESHOLD="$2"; shift 2 ;;
    --filter)           export EVAL_FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

# ---- 1. Harvest provider credentials (same approach as local-review.sh) -------
# Only allowlisted `export VAR=...` lines are parsed (never whole rc files), and
# values are assigned by parsing (never eval'd) so URL/query chars are safe.
harvest_var() {
  local var="$1" rc raw val
  [ -n "${!var:-}" ] && return 0
  for rc in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" \
            "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    raw=$(grep -E "^[[:space:]]*export[[:space:]]+${var}=" "$rc" 2>/dev/null | tail -1)
    [ -z "$raw" ] && continue
    val="${raw#*=}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
      \"*)   val="${val#\"}"; val="${val%%\"*}" ;;
      \'*)   val="${val#\'}"; val="${val%%\'*}" ;;
    esac
    export "$var=$val"
    return 0
  done
  return 1
}
for v in OPENCODE_REVIEW_REPORT_GEMINI_URL OPENCODE_GEMINI_API_KEY \
         OPENCODE_REVIEW_REPORT_COPILOT_URL OPENCODE_COPILOT_API_KEY \
         OPENCODE_REVIEW_REPORT_OPENAI_URL OPENCODE_OPENAI_API_KEY \
         OPENCODE_GO_OPENAI_API_KEY \
         OPENCODE_GO_ANTHROPIC_API_KEY \
         OPENCODE_OPENROUTER_API_KEY; do
  harvest_var "$v" || true
done

# ---- 2. macOS timeout shim (review-in-chunks.sh uses `timeout 300s`) ----------
SHIM_BIN="$(mktemp -d "${TMPDIR:-/tmp}/eval-shims.XXXXXX")"
trap 'rm -rf "$SHIM_BIN"' EXIT
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    ln -sf "$(command -v gtimeout)" "$SHIM_BIN/timeout"
  else
    # Portable perl shim that runs the command in its own process group and
    # kills the whole group on timeout (so a hung opencode grandchild can't leak).
    cat > "$SHIM_BIN/timeout" << 'SHIM_EOF'
#!/bin/bash
DURATION="$1"; shift
DURATION="${DURATION%s}"
exec perl -e '
  my $dur = shift;
  my $pid = fork();
  if (!defined $pid) { die "fork: $!"; }
  if ($pid == 0) { setpgrp(0,0); exec @ARGV or exit 127; }
  $SIG{ALRM} = sub { kill("KILL", -$pid); exit 124; };
  alarm $dur;
  waitpid($pid, 0);
  my $st = $?;
  alarm 0;
  exit($st >> 8 ? ($st >> 8) : ($st & 127 ? 128 + ($st & 127) : 0));
' -- "$DURATION" "$@"
SHIM_EOF
    chmod +x "$SHIM_BIN/timeout"
  fi
  export PATH="$SHIM_BIN:$PATH"
fi

# ---- 3. Model chain + provider selector --------------------------------------
# Same OPENCODE_REVIEW_REPORT_* names the gate uses, so the eval runs the designed
# models. Secondary/orchestrator default to the chosen PRIMARY model (not a Gemini
# literal) so a non-GEMINI chain stays same-family for lib/resolve-provider.sh.
export OPENCODE_REVIEW_REPORT_PROVIDER
export OPENCODE_REVIEW_REPORT_MODEL_PRIMARY="$OPENCODE_MODEL"
export OPENCODE_REVIEW_REPORT_MODEL_SECONDARY="${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-$OPENCODE_MODEL}"
export OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR="${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-$OPENCODE_MODEL}"

# ---- 4. Hand off to the core runner (does resolve + config + health + loop) ---
exec bash "$SCRIPT_DIR/run-evals.sh"
