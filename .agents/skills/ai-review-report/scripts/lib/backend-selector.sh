#!/usr/bin/env bash
# LADR-124: one selector chooses the model-execution backend. Safe to source:
# every variable is function-local, so a caller's SCRIPT_DIR/REPO_ROOT survive.

resolve_backend() {
  local _v="${OPENCODE_REVIEW_REPORT_BACKEND:-opencode}"
  [ -n "$_v" ] || _v=opencode
  case "$_v" in
    opencode) printf '%s' "$_v" ;;
    *)
      printf '❌ Unsupported backend "%s" — accepted values: opencode\n' "$_v" >&2
      return 1
      ;;
  esac
}

backend_display_name() {
  case "$1" in
    opencode) printf 'OpenCode' ;;
    *) return 1 ;;
  esac
}

backend_home_url() {
  case "$1" in
    opencode) printf 'https://opencode.ai' ;;
    *) return 1 ;;
  esac
}
