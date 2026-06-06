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
  GEMINI)  _rp_id="litellm-gemini"; _rp_url_var="OPENCODE_GEMINI_URL"; _rp_key_var="OPENCODE_GEMINI_API_KEY" ;;
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

# Every provider requires an explicit model chain whose ids match that provider's
# model family — fail fast HERE rather than letting a stale id fall through to
# `opencode run`. GEMINI expects gemini-* ids; COPILOT/OPENAI expect gpt-* ids
# (the only models declared per provider in assets/opencode.json). This validates
# the default GEMINI path too, so a leftover gpt-* (or vice-versa) is caught.
if [ "$OPENCODE_PROVIDER" = "GEMINI" ]; then
  _rp_expected_prefix="gemini"
else
  _rp_expected_prefix="gpt-"
fi
for _rp_mv in OPENCODE_MODEL_PRIMARY_REVIEW OPENCODE_MODEL_SECONDARY_REVIEW OPENCODE_MODEL_ORCHESTRATOR; do
  _rp_val="${!_rp_mv}"
  [ -n "$_rp_val" ] || _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_mv is unset. Set the OPENCODE_MODEL_* Variables to this provider's models."
  case "$(printf '%s' "$_rp_val" | tr '[:upper:]' '[:lower:]')" in
    ${_rp_expected_prefix}*) ;;
    *) _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_mv='$_rp_val' is not a valid $OPENCODE_PROVIDER model (expected an id starting with '${_rp_expected_prefix}'). It won't resolve on the $OPENCODE_PROVIDER gateway." ;;
  esac
done

# Gateway health-check URL (host root + a list-models path). There is no
# universal health endpoint, and the path that actually answers depends on the
# API SURFACE at the URL — NOT on the logical provider. LiteLLM (or any
# OpenAI-compatible proxy) can front ANY provider, in which case the surface is
# OpenAI-compatible (`/v1/models`) regardless of which models sit behind it.
# So the default is keyed off the URL first, provider second:
#   * Google host (generativelanguage.googleapis.com) → /v1beta/models — the
#     ONLY surface that is genuinely Gemini-native (no /health, no /v1/models).
#   * any other host → an OpenAI-compatible proxy/API (LiteLLM, OpenAI, Azure,
#     a proxied Gemini, …) → /v1/models, except Copilot whose native surface
#     lists at /models (LiteLLM also serves /models, so this holds when proxied).
# OPENCODE_API_HEALTH_OVERRIDE always wins — e.g. set it to "/health" to use a
# LiteLLM proxy's healthy/unhealthy model summary, or to a sub-path. The path is
# always taken relative to the host root.
if [ -n "${OPENCODE_API_HEALTH_OVERRIDE:-}" ]; then
  _rp_health_path="${OPENCODE_API_HEALTH_OVERRIDE}"
else
  case "$OPENCODE_GATEWAY_URL" in
    *generativelanguage.googleapis.com*) _rp_health_path="/v1beta/models" ;;   # Gemini-native surface
    *)
      case "$OPENCODE_PROVIDER" in
        COPILOT) _rp_health_path="/models" ;;
        *)       _rp_health_path="/v1/models" ;;   # OpenAI-compatible (incl. LiteLLM-fronted Gemini)
      esac
      ;;
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

unset _rp_id _rp_url_var _rp_key_var _rp_mv _rp_val _rp_health_path _rp_expected_prefix
