#!/bin/bash
# resolve-provider.sh — central provider selector for the OpenCode review pipeline.
#
# Single source of truth that maps the user-facing OPENCODE_REVIEW_REPORT_PROVIDER selector
# (GEMINI | COPILOT | OPENAI | OPENCODE-GO-OPENAI | OPENCODE-GO-ANTHROPIC,
# default COPILOT) onto:
#   - OPENCODE_REVIEW_REPORT_PROVIDER_ID         the provider KEY in assets/opencode.json that
#                                  opencode-with-fallback.sh prefixes onto the
#                                  model (`opencode run --model <id>/<model>`):
#                                    GEMINI                → gemini
#                                    COPILOT               → github-copilot
#                                    OPENAI                → openai
#                                    OPENCODE-GO-OPENAI    → go-openai
#                                    OPENCODE-GO-ANTHROPIC → go-anthropic
#                                  OpenCode Go is split into two providers because
#                                  it serves two SDK surfaces under one Zen gateway:
#                                  OpenAI-compatible (deepseek/kimi) and
#                                  Anthropic-compatible (qwen/minimax). A single
#                                  opencode.json provider block can pin only one npm.
#   - OPENCODE_REVIEW_REPORT_GATEWAY_URL /       the selected provider's gateway credentials,
#     OPENCODE_GATEWAY_API_KEY     copied out of the provider-specific
#                                  OPENCODE_REVIEW_REPORT_<P>_URL / OPENCODE_<P>_API_KEY pair
#                                  (EXCEPT the fixed-endpoint providers: the two
#                                  OpenCode Go providers, whose URL is the fixed
#                                  literal https://opencode.ai/zen/go/v1, and
#                                  COPILOT, whose URL is the fixed Copilot
#                                  endpoint https://api.githubcopilot.com — for
#                                  these only the API key comes from an env var,
#                                  and COPILOT's key is OPENCODE_COPILOT_API_KEY).
#                                  These generic names are what the credential
#                                  presence checks read, so that check is not
#                                  Gemini-specific. (Health is checked separately
#                                  and provider-agnostically via the opencode
#                                  server — lib/opencode-health.sh — not here.)
#                                  The provider-specific names stay exported too —
#                                  opencode.json's {env:OPENCODE_<P>_*}
#                                  substitution references those literal names.
#
# Fail-fast (per LADR — provider switch): a misconfigured run dies here with an
# actionable message rather than limping on to a confusing empty/auth-error review:
#   - the selected provider's URL + API key must be non-empty;
#   - for any provider OTHER than GEMINI, the resolved review-model chain
#     (OPENCODE_REVIEW_REPORT_MODEL_PRIMARY / _SECONDARY / _ORCHESTRATOR) must be
#     set and must NOT name a `gemini*` model — those IDs don't resolve on the
#     Copilot/OpenAI gateways (their declared models are gpt-5.5 / gpt-5.4 /
#     gpt-5.4-mini in opencode.json).
#
# Dual-mode: exports the resolved vars into the current shell (so it can be
# `source`d by local-review.sh) and, when running as a CI step ($GITHUB_ENV set),
# also appends them to $GITHUB_ENV so later steps inherit them. `exit 1` on
# failure terminates the parent in both modes (intended — abort the run).

_rp_die() { echo "❌ $*" >&2; exit 1; }

OPENCODE_REVIEW_REPORT_PROVIDER="${OPENCODE_REVIEW_REPORT_PROVIDER:-COPILOT}"
OPENCODE_REVIEW_REPORT_PROVIDER="$(printf '%s' "$OPENCODE_REVIEW_REPORT_PROVIDER" | tr '[:lower:]' '[:upper:]')"

# OpenCode Go's gateway is a fixed public endpoint (the OpenCode Zen base
# https://opencode.ai/zen/go/v1, hardcoded in opencode.json too), so its
# providers carry no URL env var — _rp_url_fixed supplies the value the health
# probe needs. COPILOT is the same shape: a fixed endpoint
# (https://api.githubcopilot.com, built into the @ai-sdk/github-copilot SDK),
# and its only credential is OPENCODE_COPILOT_API_KEY — a GitHub token with
# Copilot access (no per-deployment URL Variable, no separate API-key Secret). The other providers read their gateway URL from an env var.
_rp_url_fixed=""
case "$OPENCODE_REVIEW_REPORT_PROVIDER" in
  GEMINI)                _rp_id="gemini";         _rp_url_var="OPENCODE_REVIEW_REPORT_GEMINI_URL";        _rp_key_var="OPENCODE_GEMINI_API_KEY" ;;
  COPILOT)               _rp_id="github-copilot"; _rp_url_var="";  _rp_url_fixed="https://api.githubcopilot.com"; _rp_key_var="OPENCODE_COPILOT_API_KEY" ;;
  OPENAI)                _rp_id="openai";         _rp_url_var="OPENCODE_REVIEW_REPORT_OPENAI_URL";         _rp_key_var="OPENCODE_OPENAI_API_KEY" ;;
  OPENCODE-GO-OPENAI)    _rp_id="go-openai";      _rp_url_var="";  _rp_url_fixed="https://opencode.ai/zen/go/v1"; _rp_key_var="OPENCODE_GO_OPENAI_API_KEY" ;;
  OPENCODE-GO-ANTHROPIC) _rp_id="go-anthropic";   _rp_url_var="";  _rp_url_fixed="https://opencode.ai/zen/go/v1"; _rp_key_var="OPENCODE_GO_ANTHROPIC_API_KEY" ;;
  *) _rp_die "Unknown OPENCODE_REVIEW_REPORT_PROVIDER='$OPENCODE_REVIEW_REPORT_PROVIDER' (expected GEMINI, COPILOT, OPENAI, OPENCODE-GO-OPENAI, or OPENCODE-GO-ANTHROPIC)." ;;
esac

OPENCODE_REVIEW_REPORT_PROVIDER_ID="$_rp_id"
if [ -n "$_rp_url_var" ]; then
  OPENCODE_REVIEW_REPORT_GATEWAY_URL="${!_rp_url_var}"
else
  OPENCODE_REVIEW_REPORT_GATEWAY_URL="$_rp_url_fixed"
fi
OPENCODE_GATEWAY_API_KEY="${!_rp_key_var}"

# Selected provider's credentials must be present. (For OpenCode Go the URL is
# the fixed Zen base above, so this only ever trips for an env-driven provider.)
[ -n "$OPENCODE_REVIEW_REPORT_GATEWAY_URL" ]     || _rp_die "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER selected but ${_rp_url_var:-its gateway URL} is empty/unset. Set it (GitHub Variable / shell export)."
[ -n "$OPENCODE_GATEWAY_API_KEY" ] || _rp_die "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER selected but $_rp_key_var is empty/unset. Set it (GitHub Secret / shell export)."

# Every provider requires an explicit model chain. We don't enumerate every valid
# id — non-Gemini gateways serve many families (gpt-*, o*, claude-*, …) and an
# allow-list would block future ones. Instead fail fast HERE only on the mismatch
# guaranteed to break: a GEMINI gateway needs gemini-* ids, and a non-GEMINI
# gateway must NOT carry a leftover gemini-* id (it won't resolve on Copilot/OpenAI).
for _rp_mv in OPENCODE_REVIEW_REPORT_MODEL_PRIMARY OPENCODE_REVIEW_REPORT_MODEL_SECONDARY OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR; do
  _rp_val="${!_rp_mv}"
  [ -n "$_rp_val" ] || _rp_die "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER selected but $_rp_mv is unset. Set the OPENCODE_REVIEW_REPORT_MODEL_* Variables to this provider's models."
  _rp_lc="$(printf '%s' "$_rp_val" | tr '[:upper:]' '[:lower:]')"
  if [ "$OPENCODE_REVIEW_REPORT_PROVIDER" = "GEMINI" ]; then
    case "$_rp_lc" in
      gemini*) ;;
      *) _rp_die "OPENCODE_REVIEW_REPORT_PROVIDER=GEMINI selected but $_rp_mv='$_rp_val' is not a Gemini model (expected an id starting with 'gemini'). It won't resolve on the Gemini gateway." ;;
    esac
  else
    case "$_rp_lc" in
      gemini*) _rp_die "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER selected but $_rp_mv='$_rp_val' is a Gemini model. It won't resolve on the $OPENCODE_REVIEW_REPORT_PROVIDER gateway — set the OPENCODE_REVIEW_REPORT_MODEL_* Variables to this provider's models." ;;
      *) ;;
    esac
  fi
done

# Health checking is no longer per-provider. The single health signal is opencode
# itself (lib/opencode-health.sh: `opencode serve` + /global/health), which is
# identical for every provider — so there is no gateway health URL or per-surface
# auth style to derive here. This resolver only maps the provider → id + creds and
# fails fast on a bad model chain; the credential presence checks above guard the
# key. (Removed: OPENCODE_GATEWAY_HEALTH_URL, OPENCODE_GATEWAY_AUTH_STYLE,
# OPENCODE_API_HEALTH_OVERRIDE.)

export OPENCODE_REVIEW_REPORT_PROVIDER OPENCODE_REVIEW_REPORT_PROVIDER_ID OPENCODE_REVIEW_REPORT_GATEWAY_URL OPENCODE_GATEWAY_API_KEY

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER"
    echo "OPENCODE_REVIEW_REPORT_PROVIDER_ID=$OPENCODE_REVIEW_REPORT_PROVIDER_ID"
    echo "OPENCODE_REVIEW_REPORT_GATEWAY_URL=$OPENCODE_REVIEW_REPORT_GATEWAY_URL"
    echo "OPENCODE_GATEWAY_API_KEY=$OPENCODE_GATEWAY_API_KEY"
  } >> "$GITHUB_ENV"
fi

echo "🔀 OpenCode provider: $OPENCODE_REVIEW_REPORT_PROVIDER (provider-id: $OPENCODE_REVIEW_REPORT_PROVIDER_ID)"

unset _rp_id _rp_url_var _rp_url_fixed _rp_key_var _rp_mv _rp_val _rp_lc
