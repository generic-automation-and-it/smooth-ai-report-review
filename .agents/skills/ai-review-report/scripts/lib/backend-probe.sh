#!/usr/bin/env bash
# LADR-124: the probe seam. One liveness probe for every call site; callers keep
# their own classification (ERROR_PATTERN, plus empty output for the background
# orchestrator probe). Safe to source: function-local variables only.

backend_probe() { # backend_probe <backend> <provider-id> <model> [timeout]
  local _backend="$1" _provider="$2" _model="$3" _timeout="${4:-}"
  case "$_backend" in
    opencode)
      if [ -n "$_timeout" ]; then
        timeout "$_timeout" opencode run \
          --agent review \
          --model "${_provider}/${_model}" \
          --format default \
          --log-level warn \
          "Say 'OK'" 2>&1 || true
      else
        opencode run \
          --agent review \
          --model "${_provider}/${_model}" \
          --format default \
          --log-level warn \
          "Say 'OK'" 2>&1 || true
      fi
      ;;
    pi)
      local _dir _policy _keyvar _allow _v _root
      _dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
      _policy="$_dir/../../assets/pi/policy.js"
      _keyvar="$(. "$_dir/prepare-pi-config.sh"; pi_key_var_for_provider "$_provider")" || return 1
      _allow="PATH HOME TMPDIR TMP TEMP LANG LC_ALL LC_CTYPE PI_CODING_AGENT_DIR PI_ROLE PI_WORKSPACE_ROOT PI_TELEMETRY PI_SKIP_VERSION_CHECK PI_OFFLINE $_keyvar"
      _root="$(git -C "${OPENCODE_RUN_CWD:-$PWD}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${OPENCODE_RUN_CWD:-$PWD}")"
      if [ -n "$_timeout" ]; then
        (
          for _v in $(compgen -e); do case " $_allow " in *" $_v "*) ;; *) unset "$_v" ;; esac; done
          PI_ROLE=review PI_WORKSPACE_ROOT="$_root" PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-}"             timeout "$_timeout" pi --print --no-session --no-approve -nc -ns -np --no-mcp -ne \
              -e "$_policy" --model "${_provider}/${_model}" "Say 'OK'" 2>&1 || true
        )
      else
        (
          for _v in $(compgen -e); do case " $_allow " in *" $_v "*) ;; *) unset "$_v" ;; esac; done
          PI_ROLE=review PI_WORKSPACE_ROOT="$_root" PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-}"             pi --print --no-session --no-approve -nc -ns -np --no-mcp -ne \
              -e "$_policy" --model "${_provider}/${_model}" "Say 'OK'" 2>&1 || true
        )
      fi
      ;;
    *)
      printf '❌ Unsupported backend "%s" in backend_probe\n' "$_backend" >&2
      return 1
      ;;
  esac
}
