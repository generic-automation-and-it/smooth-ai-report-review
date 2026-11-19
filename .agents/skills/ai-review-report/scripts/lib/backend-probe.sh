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
      if [ -n "$_timeout" ]; then
        timeout "$_timeout" pi --print --no-session --no-approve -nc -ns -np --no-mcp -ne \
          --model "${_provider}/${_model}" "Say 'OK'" 2>&1 || true
      else
        pi --print --no-session --no-approve -nc -ns -np --no-mcp -ne \
          --model "${_provider}/${_model}" "Say 'OK'" 2>&1 || true
      fi
      ;;
    *)
      printf '❌ Unsupported backend "%s" in backend_probe\n' "$_backend" >&2
      return 1
      ;;
  esac
}
