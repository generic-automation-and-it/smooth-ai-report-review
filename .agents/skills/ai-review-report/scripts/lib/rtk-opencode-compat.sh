#!/bin/bash
# rtk-opencode-compat.sh — single source of truth for whether an installed RTK
# can drive OpenCode v2 (LADR-054, LADR-087). Sourced by install-rtk.sh (which
# decides whether to run `rtk init --opencode`) and check-versions.sh (which
# renders the bypass warning), so the two can never disagree.
#
# RTK never shipped a separate `--opencode-v2` flag. From v0.52.0
# (rtk-ai/rtk#3463) the existing `rtk init --opencode` writes one plugin that
# registers both OpenCode 2.x's `execute.before` and 1.x's `tool.execute.before`
# hooks without importing `@opencode-ai/plugin`. Older releases write a v1-only
# plugin that OpenCode v2 cannot load, so the CLI surface cannot be probed — the
# release floor is the compatibility contract.

RTK_OPENCODE_V2_MIN_VERSION="0.52.0"

# rtk_supports_opencode_v2 <rtk-version> — true when the version is at or above
# the floor. An empty or unparseable version is treated as unsupported.
rtk_supports_opencode_v2() {
  local _version="${1#v}"
  case "$_version" in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  # install-rtk.sh and check-versions.sh parse `rtk --version` with
  # `[0-9]+(\.[0-9]+){1,3}`, so a two-component "0.52" is a real input. `sort -V`
  # orders "0.52" BEFORE "0.52.0", which made the floor reject a release that is
  # exactly at it; pad to three components before comparing.
  case "$_version" in
    *.*.*) ;;
    *.*) _version="${_version}.0" ;;
    *) _version="${_version}.0.0" ;;
  esac
  [ "$(printf '%s\n%s\n' "$RTK_OPENCODE_V2_MIN_VERSION" "$_version" | sort -V | head -1)" = "$RTK_OPENCODE_V2_MIN_VERSION" ]
}
