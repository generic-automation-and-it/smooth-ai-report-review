#!/usr/bin/env bash
# LADR-124: the initialize seam. OpenCode stops any leftover background service,
# warms the SQLite store and verifies the managed-config binding. Exit 3 is the
# caller's fatal configuration failure; every other non-zero stays advisory
# (LADR-028/087). Safe to source: function-local variables only.

initialize_backend() { # initialize_backend <backend> <lib-dir>
  local _backend="$1" _lib_dir="$2"
  case "$_backend" in
    opencode)
      opencode service stop >/dev/null 2>&1 || true
      opencode stats >/dev/null 2>&1 || true
      bash "$_lib_dir/opencode-health.sh"
      ;;
    pi)
      local _pin="${OPENCODE_TOOL_PI_VERSION#v}" _installed _id _models
      _installed="$(pi --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -1)"
      if [ -z "$_installed" ]; then
        printf '❌ pi is not on PATH\n' >&2
        return 3
      fi
      if [ -n "$_pin" ] && [ "$_installed" != "$_pin" ]; then
        printf '❌ pi %s does not match OPENCODE_TOOL_PI_VERSION %s\n' "$_installed" "$_pin" >&2
        return 3
      fi
      if [ -z "${PI_CODING_AGENT_DIR:-}" ] || [ ! -d "$PI_CODING_AGENT_DIR" ]; then
        printf '❌ PI_CODING_AGENT_DIR is not the prepared directory\n' >&2
        return 3
      fi
      _id="${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-}"
      if ! pi auth check --provider "$_id" 2>/dev/null | grep -qE '^ready$'; then
        printf '❌ pi has no credentials ready for provider %s\n' "$_id" >&2
        return 3
      fi
      for _id in ${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-} ${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-} ${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-}; do
        [ -n "$_id" ] || continue
        if ! grep -q "\"$_id\"" "$PI_CODING_AGENT_DIR/models.json" 2>/dev/null; then
          printf '❌ pi models.json does not list requested model %s\n' "$_id" >&2
          return 3
        fi
      done
      ;;
    *)
      printf '❌ Unsupported backend "%s" in initialize_backend\n' "$_backend" >&2
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  initialize_backend "$@"
fi
