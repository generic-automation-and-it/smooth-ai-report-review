#!/bin/bash
# prepare-pi-config.sh — builds the gate-owned pi agent directory (LADR-126).
#
# Sourced, never executed: `prepare_pi_config` writes models.json + settings.json
# into a run-local 0700 directory outside the checkout and exports
# PI_CODING_AGENT_DIR. The provider roster is DERIVED from the already-resolved
# OPENCODE_CONFIG (built-in asset, LADR-047 override, LADR-034 injected URL,
# LADR-107 registered models), so there is one roster. Keys are `$NAME`
# references, never values. Function-local variables only.

pi_key_var_for_provider() { # pi_key_var_for_provider <provider-id>
  local _id="$1" _cfg="${OPENCODE_CONFIG:-}" _placeholder=""
  # The resolved config's placeholder wins for EVERY id, so a credential
  # override in an LADR-047 config reaches pi; known ids are only the fallback.
  if [ -n "$_cfg" ] && [ -r "$_cfg" ] && command -v jq >/dev/null 2>&1; then
    _placeholder="$(jq -r --arg p "$_id" \
      '((.provider // .providers // {})[$p].options.apiKey // "")' "$_cfg" 2>/dev/null || true)"
    case "$_placeholder" in
      '{env:'*'}') _placeholder="${_placeholder#\{env:}"; _placeholder="${_placeholder%\}}" ;;
      '') ;;
      *) printf '❌ Provider "%s" has a literal apiKey; a {env:NAME} reference is required for pi\n' "$_id" >&2; return 1 ;;
    esac
    if [ -n "$_placeholder" ]; then
      printf '%s' "$_placeholder" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' \
        || { printf '❌ Provider "%s" placeholder is not a valid variable name\n' "$_id" >&2; return 1; }
      printf '%s' "$_placeholder"
      return 0
    fi
  fi
  case "$_id" in
    gemini) printf 'OPENCODE_GEMINI_API_KEY' ;;
    github-copilot) printf 'OPENCODE_COPILOT_API_KEY' ;;
    openai) printf 'OPENCODE_OPENAI_API_KEY' ;;
    anthropic) printf 'OPENCODE_ANTHROPIC_API_KEY' ;;
    go-openai) printf 'OPENCODE_GO_OPENAI_API_KEY' ;;
    go-anthropic) printf 'OPENCODE_GO_ANTHROPIC_API_KEY' ;;
    go-responses) printf 'OPENCODE_GO_OPENAI_API_KEY' ;;
    openrouter) printf 'OPENCODE_OPENROUTER_API_KEY' ;;
    *)
      printf '❌ No pi credential mapping for provider "%s"\n' "$_id" >&2
      return 1
      ;;
  esac
}

_pi_api_for() { # _pi_api_for <provider-id> <npm-sdk>
  local _id="$1" _sdk="$2"
  case "$_id" in
    go-responses) printf 'openai-responses'; return 0 ;;
  esac
  case "$_sdk" in
    '') case "$_id" in
          gemini) printf 'google-generative-ai' ;;
          github-copilot|openai|go-openai|openrouter) printf 'openai-completions' ;;
          anthropic|go-anthropic) printf 'anthropic-messages' ;;
          go-responses) printf 'openai-responses' ;;
          *) return 1 ;;
        esac ;;
    '@ai-sdk/google') printf 'google-generative-ai' ;;
    '@ai-sdk/github-copilot') printf 'openai-completions' ;;
    '@ai-sdk/openai') printf 'openai-completions' ;;
    '@ai-sdk/openai-compatible') printf 'openai-completions' ;;
    '@ai-sdk/anthropic') printf 'anthropic-messages' ;;
    '@openrouter/ai-sdk-provider') printf 'openai-completions' ;;
    *) return 1 ;;
  esac
}

prepare_pi_config() { # prepare_pi_config <settings-asset>
  local _settings_asset="$1" _cfg="${OPENCODE_CONFIG:-}" _dir _ids _id _sdk _api _url _key _models _required
  if [ -z "$_cfg" ] || [ ! -r "$_cfg" ]; then
    printf '❌ prepare_pi_config: OPENCODE_CONFIG is unset or unreadable\n' >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf '❌ prepare_pi_config: jq is required\n' >&2; return 1; }
  [ -r "$_settings_asset" ] || { printf '❌ prepare_pi_config: settings asset missing\n' >&2; return 1; }

  _dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pi-agent.XXXXXX")" || return 1
  chmod 700 "$_dir" || return 1
  local _ws _real_dir
  _ws="$(git -C "${GITHUB_WORKSPACE:-$PWD}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${GITHUB_WORKSPACE:-$PWD}")"
  _ws="$(cd "$_ws" 2>/dev/null && pwd -P)" || true
  _real_dir="$(cd "$_dir" && pwd -P)"
  case "$_real_dir" in
    "$_ws"|"$_ws"/*) printf '❌ prepare_pi_config: agent directory is inside the checkout\n' >&2; rm -rf "$_dir"; return 1 ;;
  esac

  _ids="$(jq -r '(.provider // .providers // {}) | keys[]' "$_cfg")"
  _required="${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-} ${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-} ${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-} ${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-}"

  {
    printf '{\n  "providers": {\n'
    local _first=1
    while IFS= read -r _id; do
      [ -n "$_id" ] || continue
      _sdk="$(jq -r --arg p "$_id" '((.provider // .providers)[$p].npm // "")' "$_cfg")"
      if ! _api="$(_pi_api_for "$_id" "$_sdk")"; then
        case "$_required" in
          *"$_id"*)
            printf '❌ Provider "%s" (SDK "%s") has no pi api mapping and is part of the requested chain\n' "$_id" "$_sdk" >&2
            rm -rf "$_dir"
            return 1
            ;;
          *) continue ;;
        esac
      fi
      _url="$(jq -r --arg p "$_id" '((.provider // .providers)[$p].options.baseURL // "")' "$_cfg" 2>/dev/null || true)"
      case "$_url" in
        *://*@*) printf '❌ Provider "%s" base URL embeds credentials; a credential-free URL is required\n' "$_id" >&2; rm -rf "$_dir"; return 1 ;;
      esac
      case "$_url" in
        *[?\&]*=*) case "$_url" in
          *[?\&]api[_-]?key=*|*[?\&]key=*|*[?\&]token=*|*[?\&]access_token=*|*[?\&]sig=*|*[?\&]secret=*)
            printf '❌ Provider "%s" base URL carries a credential in its query string\n' "$_id" >&2; rm -rf "$_dir"; return 1 ;;
        esac ;;
      esac
      _key="$(pi_key_var_for_provider "$_id")" || { rm -rf "$_dir"; return 1; }
      _models="$(jq -r --arg p "$_id" '((.provider // .providers)[$p].models // {}) | keys[]' "$_cfg")"
      [ "$_first" -eq 1 ] || printf ',\n'
      _first=0
      printf '    "%s": {\n' "$_id"
      if [ -n "$_url" ]; then printf '      "baseUrl": "%s",\n' "$_url"; fi
      printf '      "api": "%s",\n      "apiKey": "$%s",\n      "models": [' "$_api" "$_key"
      local _mfirst=1 _m
      while IFS= read -r _m; do
        [ -n "$_m" ] || continue
        [ "$_mfirst" -eq 1 ] || printf ', '
        _mfirst=0
        printf '{"id": "%s"}' "$_m"
      done <<< "$_models"
      printf ']\n    }'
    done <<< "$_ids"
    printf '\n  }\n}\n'
  } > "$_dir/models.json" || { rm -rf "$_dir"; return 1; }

  cp "$_settings_asset" "$_dir/settings.json" || { rm -rf "$_dir"; return 1; }
  export PI_CODING_AGENT_DIR="$_dir"
  printf '✓ pi agent directory prepared: %s\n' "$PI_CODING_AGENT_DIR"
}
