#!/bin/bash
# resolve-provider.sh — central provider selector for the OpenCode review pipeline.
#
# Single source of truth that maps the user-facing OPENCODE_PROVIDER selector
# (GEMINI | COPILOT | OPENAI, default GEMINI) onto:
#   - OPENCODE_PROVIDER_ID         the provider KEY in assets/opencode.json that
#                                  opencode-with-fallback.sh prefixes onto the
#                                  model (`opencode run --model <id>/<model>`):
#                                    GEMINI  → litellm-gemini
#                                    COPILOT → github-copilot
#                                    OPENAI  → openai
#   - OPENCODE_GATEWAY_URL /       the selected provider's gateway credentials,
#     OPENCODE_GATEWAY_API_KEY     copied out of the provider-specific
#                                  OPENCODE_<P>_URL / OPENCODE_<P>_API_KEY pair.
#                                  These generic names are what the bash-side
#                                  /health probe + presence checks read, so those
#                                  checks are no longer Gemini-specific. The
#                                  provider-specific names stay exported too —
#                                  opencode.json's {env:OPENCODE_<P>_*}
#                                  substitution references those literal names.
#
# Fail-fast (per LADR — provider switch): a misconfigured run dies here with an
# actionable message rather than limping on to a confusing empty/auth-error review:
#   - the selected provider's URL + API key must be non-empty;
#   - for any provider OTHER than GEMINI, the resolved review-model chain
#     (OPENCODE_MODEL_PRIMARY_REVIEW / _SECONDARY_REVIEW / _ORCHESTRATOR) must be
#     set and must NOT name a `gemini*` model — those IDs don't resolve on the
#     Copilot/OpenAI gateways (their declared models are gpt-5.5 / gpt-5.4 /
#     gpt-5.4-mini in opencode.json).
#
# Dual-mode: exports the resolved vars into the current shell (so it can be
# `source`d by local-review.sh) and, when running as a CI step ($GITHUB_ENV set),
# also appends them to $GITHUB_ENV so later steps inherit them. `exit 1` on
# failure terminates the parent in both modes (intended — abort the run).

_rp_die() { echo "❌ $*" >&2; exit 1; }

OPENCODE_PROVIDER="${OPENCODE_PROVIDER:-GEMINI}"
OPENCODE_PROVIDER="$(printf '%s' "$OPENCODE_PROVIDER" | tr '[:lower:]' '[:upper:]')"

case "$OPENCODE_PROVIDER" in
  GEMINI)  _rp_id="litellm-gemini"; _rp_url_var="OPENCODE_GEMININ_URL"; _rp_key_var="OPENCODE_GEMININ_API_KEY" ;;
  COPILOT) _rp_id="github-copilot"; _rp_url_var="OPENCODE_COPILOT_URL"; _rp_key_var="OPENCODE_COPILOT_API_KEY" ;;
  OPENAI)  _rp_id="openai";         _rp_url_var="OPENCODE_OPENAI_URL";  _rp_key_var="OPENCODE_OPENAI_API_KEY" ;;
  *) _rp_die "Unknown OPENCODE_PROVIDER='$OPENCODE_PROVIDER' (expected GEMINI, COPILOT, or OPENAI)." ;;
esac

OPENCODE_PROVIDER_ID="$_rp_id"
OPENCODE_GATEWAY_URL="${!_rp_url_var}"
OPENCODE_GATEWAY_API_KEY="${!_rp_key_var}"

# Selected provider's credentials must be present.
[ -n "$OPENCODE_GATEWAY_URL" ]     || _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_url_var is empty/unset. Set it (GitHub Variable / shell export)."
[ -n "$OPENCODE_GATEWAY_API_KEY" ] || _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_key_var is empty/unset. Set it (GitHub Secret / shell export)."

# Non-GEMINI providers require an explicit, non-gemini model chain.
if [ "$OPENCODE_PROVIDER" != "GEMINI" ]; then
  for _rp_mv in OPENCODE_MODEL_PRIMARY_REVIEW OPENCODE_MODEL_SECONDARY_REVIEW OPENCODE_MODEL_ORCHESTRATOR; do
    _rp_val="${!_rp_mv}"
    [ -n "$_rp_val" ] || _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_mv is unset. Set the OPENCODE_MODEL_* Variables to this provider's models (e.g. gpt-5.5 / gpt-5.4 / gpt-5.4-mini)."
    case "$(printf '%s' "$_rp_val" | tr '[:upper:]' '[:lower:]')" in
      gemini*) _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_mv='$_rp_val' names a Gemini model, which won't resolve on the $OPENCODE_PROVIDER gateway. Set OPENCODE_MODEL_* to $OPENCODE_PROVIDER models (e.g. gpt-5.5 / gpt-5.4 / gpt-5.4-mini)." ;;
    esac
  done
fi

# Gateway health-check URL (host root + a per-provider path). There is no
# universal health endpoint — each provider's native API exposes a different
# liveness/availability check, and none of them is a generic "/health" (that
# is LiteLLM-specific). The default is therefore keyed to each provider's
# OWN API, so this is agnostic to whether a LiteLLM proxy sits in front:
#   GEMINI  → /v1beta/models   (Google Generative Language API list-models;
#                               native Gemini has no /health)
#   OPENAI  → /v1/models       (OpenAI list-models)
#   COPILOT → /models          (Copilot list-models)
# OPENCODE_API_HEALTH_OVERRIDE wins for any gateway whose health path differs —
# notably set it to "/health" when a LiteLLM proxy fronts the models (LiteLLM
# exposes /health with a healthy/unhealthy model summary), or to a sub-path.
# The path is always taken relative to the host root.
if [ -n "${OPENCODE_API_HEALTH_OVERRIDE:-}" ]; then
  _rp_health_path="${OPENCODE_API_HEALTH_OVERRIDE}"
else
  case "$OPENCODE_PROVIDER" in
    COPILOT) _rp_health_path="/models" ;;
    OPENAI)  _rp_health_path="/v1/models" ;;
    *)       _rp_health_path="/v1beta/models" ;;   # GEMINI → Google native list-models
  esac
fi
_rp_health_path="/${_rp_health_path#/}"   # normalize to exactly one leading slash
OPENCODE_GATEWAY_HEALTH_URL="$(printf '%s' "$OPENCODE_GATEWAY_URL" | sed -E 's#(https?://[^/]+).*#\1#')${_rp_health_path}"

# Health-probe auth style. Native Google Gemini (generativelanguage.googleapis.com)
# authenticates the API key via the `x-goog-api-key` header, NOT an
# `Authorization: Bearer` token. Every other gateway we target — a LiteLLM proxy,
# native OpenAI, Copilot, or Gemini's OpenAI-compat layer — uses Bearer. Detected
# from the gateway host so the probe authenticates correctly regardless of which
# URL the user pointed the provider at (opencode itself uses the SDK's own auth).
case "$OPENCODE_GATEWAY_URL" in
  *generativelanguage.googleapis.com*) OPENCODE_GATEWAY_AUTH_STYLE="google" ;;
  *)                                   OPENCODE_GATEWAY_AUTH_STYLE="bearer" ;;
esac

export OPENCODE_PROVIDER OPENCODE_PROVIDER_ID OPENCODE_GATEWAY_URL OPENCODE_GATEWAY_API_KEY OPENCODE_GATEWAY_HEALTH_URL OPENCODE_GATEWAY_AUTH_STYLE

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "OPENCODE_PROVIDER=$OPENCODE_PROVIDER"
    echo "OPENCODE_PROVIDER_ID=$OPENCODE_PROVIDER_ID"
    echo "OPENCODE_GATEWAY_URL=$OPENCODE_GATEWAY_URL"
    echo "OPENCODE_GATEWAY_API_KEY=$OPENCODE_GATEWAY_API_KEY"
    echo "OPENCODE_GATEWAY_HEALTH_URL=$OPENCODE_GATEWAY_HEALTH_URL"
    echo "OPENCODE_GATEWAY_AUTH_STYLE=$OPENCODE_GATEWAY_AUTH_STYLE"
  } >> "$GITHUB_ENV"
fi

echo "🔀 OpenCode provider: $OPENCODE_PROVIDER (provider-id: $OPENCODE_PROVIDER_ID, health: $OPENCODE_GATEWAY_HEALTH_URL, auth: $OPENCODE_GATEWAY_AUTH_STYLE)"

unset _rp_id _rp_url_var _rp_key_var _rp_mv _rp_val _rp_health_path
