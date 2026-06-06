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
[ -n "$OPENCODE_GATEWAY_URL" ]     || _rp_die "OPENCODE_PROVIDER=$OPENCODE_PROVIDER selected but $_rp_url_var is empty/unset. Set it (GitHub Secret / shell export)."
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

export OPENCODE_PROVIDER OPENCODE_PROVIDER_ID OPENCODE_GATEWAY_URL OPENCODE_GATEWAY_API_KEY

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "OPENCODE_PROVIDER=$OPENCODE_PROVIDER"
    echo "OPENCODE_PROVIDER_ID=$OPENCODE_PROVIDER_ID"
    echo "OPENCODE_GATEWAY_URL=$OPENCODE_GATEWAY_URL"
    echo "OPENCODE_GATEWAY_API_KEY=$OPENCODE_GATEWAY_API_KEY"
  } >> "$GITHUB_ENV"
fi

echo "🔀 OpenCode provider: $OPENCODE_PROVIDER (provider-id: $OPENCODE_PROVIDER_ID)"

unset _rp_id _rp_url_var _rp_key_var _rp_mv _rp_val
