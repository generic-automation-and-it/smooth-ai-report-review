#!/bin/bash
# resolve-provider.sh — central provider selector for the OpenCode review pipeline.
#
# Single source of truth that maps a user-facing provider selector onto:
#   - <scope> provider id: the provider KEY in assets/opencode.json that
#     opencode-with-fallback.sh prefixes onto the model target.
#   - <scope> gateway URL: copied from the provider-specific URL env var when
#     configurable, or from the fixed public provider base when not.
#
# Default scope is `review`, preserving the historical behavior:
#   OPENCODE_REVIEW_REPORT_PROVIDER → OPENCODE_REVIEW_REPORT_PROVIDER_ID
#   OPENCODE_REVIEW_REPORT_PROVIDER → OPENCODE_REVIEW_REPORT_GATEWAY_URL
#
# `OPENCODE_PROVIDER_SCOPE=analyse` resolves the autonomous-fix namespace:
#   OPENCODE_ANALYSE_PROVIDER → OPENCODE_ANALYSE_PROVIDER_ID
#   OPENCODE_ANALYSE_PROVIDER → OPENCODE_ANALYSE_GATEWAY_URL
#
# If OPENCODE_ANALYSE_MODEL is set, OPENCODE_ANALYSE_PROVIDER is required so the
# analyse primary model cannot silently inherit OPENCODE_REVIEW_REPORT_PROVIDER.
# If no analyse-specific model is set, callers can keep using the review provider
# and review primary model without resolving the analyse namespace.
#
# Dual-mode: exports the resolved vars into the current shell (so it can be
# `source`d by local-review.sh) and, when running as a CI step ($GITHUB_ENV set),
# also appends non-sensitive derived vars to $GITHUB_ENV so later steps inherit
# them. API keys are never written to $GITHUB_ENV.

_rp_die() { echo "❌ $*" >&2; exit 1; }

_rp_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

_rp_provider_fields() {
  _rp_selector="$1"
  _rp_url_fixed=""
  case "$_rp_selector" in
    GEMINI)                _rp_id="gemini";         _rp_url_var="OPENCODE_REVIEW_REPORT_GEMINI_URL";  _rp_key_var="OPENCODE_GEMINI_API_KEY" ;;
    COPILOT)               _rp_id="github-copilot"; _rp_url_var="OPENCODE_REVIEW_REPORT_COPILOT_URL"; _rp_key_var="OPENCODE_COPILOT_API_KEY" ;;
    OPENAI)                _rp_id="openai";         _rp_url_var="OPENCODE_REVIEW_REPORT_OPENAI_URL";  _rp_key_var="OPENCODE_OPENAI_API_KEY" ;;
    ANTHROPIC)             _rp_id="anthropic";      _rp_url_var=""; _rp_url_fixed="https://api.anthropic.com";       _rp_key_var="OPENCODE_ANTHROPIC_API_KEY" ;;
    OPENCODE-GO-OPENAI)    _rp_id="go-openai";      _rp_url_var=""; _rp_url_fixed="https://opencode.ai/zen/go/v1";   _rp_key_var="OPENCODE_GO_OPENAI_API_KEY" ;;
    OPENCODE-GO-ANTHROPIC) _rp_id="go-anthropic";   _rp_url_var=""; _rp_url_fixed="https://opencode.ai/zen/go/v1";   _rp_key_var="OPENCODE_GO_ANTHROPIC_API_KEY" ;;
    OPEN_ROUTER)           _rp_id="openrouter";     _rp_url_var=""; _rp_url_fixed="https://openrouter.ai/api/v1";    _rp_key_var="OPENCODE_OPENROUTER_API_KEY" ;;
    *) _rp_die "Unknown provider='$_rp_selector' (expected GEMINI, COPILOT, OPENAI, ANTHROPIC, OPENCODE-GO-OPENAI, OPENCODE-GO-ANTHROPIC, or OPEN_ROUTER)." ;;
  esac
}

_rp_model_family_ok() {
  _rp_provider="$1"
  _rp_var_name="$2"
  _rp_model="$3"
  _rp_lc="$(printf '%s' "$_rp_model" | tr '[:upper:]' '[:lower:]')"

  case "$_rp_provider" in
    GEMINI)
      case "$_rp_lc" in
        gemini*) ;;
        *) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is not a Gemini model (expected an id starting with 'gemini'). It won't resolve on the Gemini gateway." ;;
      esac
      ;;
    ANTHROPIC)
      case "$_rp_lc" in
        claude*) ;;
        *) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is not a Claude model (expected an id starting with 'claude'). It won't resolve on the Anthropic gateway." ;;
      esac
      ;;
    OPENCODE-GO-OPENAI)
      case "$_rp_lc" in
        gemini*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is a Gemini model. It won't resolve on the $_rp_provider gateway." ;;
        claude*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is a Claude model. It won't resolve on the $_rp_provider gateway." ;;
        minimax*|qwen*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' belongs to the OpenCode Go Anthropic-compatible surface. Use OPENCODE-GO-ANTHROPIC for qwen/minimax models." ;;
        *) ;;
      esac
      ;;
    OPENCODE-GO-ANTHROPIC)
      case "$_rp_lc" in
        gemini*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is a Gemini model. It won't resolve on the $_rp_provider gateway." ;;
        claude*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is a Claude model. It won't resolve on the $_rp_provider gateway." ;;
        deepseek*|glm*|kimi*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' belongs to the OpenCode Go OpenAI-compatible surface. Use OPENCODE-GO-OPENAI for deepseek/glm/kimi models." ;;
        *) ;;
      esac
      ;;
    *)
      case "$_rp_lc" in
        gemini*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is a Gemini model. It won't resolve on the $_rp_provider gateway — set the OPENCODE_REVIEW_REPORT_MODEL_* Variables to this provider's models." ;;
        claude*) _rp_die "$_rp_provider selected but $_rp_var_name='$_rp_model' is a Claude model. It won't resolve on the $_rp_provider gateway — set the OPENCODE_REVIEW_REPORT_MODEL_* Variables to this provider's models." ;;
        *) ;;
      esac
      ;;
  esac
}

_rp_resolve() {
  _rp_scope="$1"
  _rp_selector_var="$2"
  _rp_default="$3"
  _rp_provider_id_var="$4"
  _rp_gateway_url_var="$5"

  _rp_raw="${!_rp_selector_var:-}"
  if [ -z "$_rp_raw" ]; then
    _rp_raw="$_rp_default"
  fi
  _rp_provider="$(_rp_upper "$_rp_raw")"
  _rp_provider_fields "$_rp_provider"

  if [ -n "$_rp_url_var" ]; then
    _rp_gateway_url="${!_rp_url_var:-}"
  else
    _rp_gateway_url="$_rp_url_fixed"
  fi
  _rp_api_key="${!_rp_key_var:-}"

  [ -n "$_rp_gateway_url" ] || _rp_die "$_rp_selector_var=$_rp_provider selected but ${_rp_url_var:-its gateway URL} is empty/unset. Set it (GitHub Variable / shell export)."
  [ -n "$_rp_api_key" ] || _rp_die "$_rp_selector_var=$_rp_provider selected but $_rp_key_var is empty/unset. Set it (GitHub Secret / shell export)."

  printf -v "$_rp_selector_var" '%s' "$_rp_provider"
  printf -v "$_rp_provider_id_var" '%s' "$_rp_id"
  printf -v "$_rp_gateway_url_var" '%s' "$_rp_gateway_url"

  export "$_rp_selector_var" "$_rp_provider_id_var" "$_rp_gateway_url_var"

  if [ "$_rp_scope" = "review" ]; then
    OPENCODE_GATEWAY_API_KEY="$_rp_api_key"
    export OPENCODE_GATEWAY_API_KEY
  fi
}

_rp_scope="${OPENCODE_PROVIDER_SCOPE:-review}"
case "$_rp_scope" in
  review)
    _rp_resolve "review" "OPENCODE_REVIEW_REPORT_PROVIDER" "GEMINI" "OPENCODE_REVIEW_REPORT_PROVIDER_ID" "OPENCODE_REVIEW_REPORT_GATEWAY_URL"

    for _rp_mv in OPENCODE_REVIEW_REPORT_MODEL_PRIMARY OPENCODE_REVIEW_REPORT_MODEL_SECONDARY OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR; do
      _rp_val="${!_rp_mv:-}"
      [ -n "$_rp_val" ] || _rp_die "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER selected but $_rp_mv is unset. Set the OPENCODE_REVIEW_REPORT_MODEL_* Variables to this provider's models."
      _rp_model_family_ok "$OPENCODE_REVIEW_REPORT_PROVIDER" "$_rp_mv" "$_rp_val"
    done

    if [ -n "${GITHUB_ENV:-}" ]; then
      {
        echo "OPENCODE_REVIEW_REPORT_PROVIDER=$OPENCODE_REVIEW_REPORT_PROVIDER"
        echo "OPENCODE_REVIEW_REPORT_PROVIDER_ID=$OPENCODE_REVIEW_REPORT_PROVIDER_ID"
        echo "OPENCODE_REVIEW_REPORT_GATEWAY_URL=$OPENCODE_REVIEW_REPORT_GATEWAY_URL"
      } >> "$GITHUB_ENV"
    fi

    echo "🔀 OpenCode provider: $OPENCODE_REVIEW_REPORT_PROVIDER (provider-id: $OPENCODE_REVIEW_REPORT_PROVIDER_ID)"
    ;;

  analyse)
    unset OPENCODE_GATEWAY_API_KEY
    if [ -n "${OPENCODE_ANALYSE_MODEL:-}" ] && [ -z "${OPENCODE_ANALYSE_PROVIDER:-}" ]; then
      _rp_die "OPENCODE_ANALYSE_MODEL is set but OPENCODE_ANALYSE_PROVIDER is unset. Set OPENCODE_ANALYSE_PROVIDER to the provider that serves OPENCODE_ANALYSE_MODEL, or unset OPENCODE_ANALYSE_MODEL to inherit the review provider/model."
    fi

    _rp_analyse_default="${OPENCODE_REVIEW_REPORT_PROVIDER:-GEMINI}"
    _rp_resolve "analyse" "OPENCODE_ANALYSE_PROVIDER" "$_rp_analyse_default" "OPENCODE_ANALYSE_PROVIDER_ID" "OPENCODE_ANALYSE_GATEWAY_URL"

    if [ -n "${OPENCODE_ANALYSE_MODEL:-}" ]; then
      _rp_model_family_ok "$OPENCODE_ANALYSE_PROVIDER" "OPENCODE_ANALYSE_MODEL" "$OPENCODE_ANALYSE_MODEL"
    fi

    if [ -n "${GITHUB_ENV:-}" ]; then
      {
        echo "OPENCODE_ANALYSE_PROVIDER=$OPENCODE_ANALYSE_PROVIDER"
        echo "OPENCODE_ANALYSE_PROVIDER_ID=$OPENCODE_ANALYSE_PROVIDER_ID"
        echo "OPENCODE_ANALYSE_GATEWAY_URL=$OPENCODE_ANALYSE_GATEWAY_URL"
      } >> "$GITHUB_ENV"
    fi

    echo "🔀 OpenCode analyse provider: $OPENCODE_ANALYSE_PROVIDER (provider-id: $OPENCODE_ANALYSE_PROVIDER_ID)"
    ;;

  *) _rp_die "Unknown OPENCODE_PROVIDER_SCOPE='$_rp_scope' (expected review or analyse)." ;;
esac

unset _rp_scope _rp_selector_var _rp_default _rp_provider_id_var _rp_gateway_url_var
unset _rp_raw _rp_provider _rp_selector _rp_id _rp_url_var _rp_url_fixed _rp_key_var
unset _rp_gateway_url _rp_api_key _rp_mv _rp_val _rp_lc _rp_analyse_default
