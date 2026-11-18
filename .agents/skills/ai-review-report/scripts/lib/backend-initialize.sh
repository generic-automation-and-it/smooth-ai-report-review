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
    *)
      printf '❌ Unsupported backend "%s" in initialize_backend\n' "$_backend" >&2
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  initialize_backend "$@"
fi
