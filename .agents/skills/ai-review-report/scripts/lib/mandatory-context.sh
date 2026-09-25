#!/bin/bash
# mandatory-context.sh — the one definition of the MANDATORY_CONTEXT_FILES
# opt-out, sourced by find-context-files.sh (which honours it) and
# local-review.sh (which must not pre-warn about it as a missing file).
#
# Two copies of this test drifted apart as soon as they existed: one counted
# words and compared the first, the other stripped all whitespace and counted
# separately. Both happened to agree; the next edit to either would not have.
#
# Bash 3.2 safe (no ${v,,}, no arrays): local-review.sh has no Bash >= 4 guard.

# mandatory_context_is_none <value>
#   True when the WHOLE value is `none` — any case, any surrounding whitespace
#   (a YAML `>-` block or a Variable can carry newlines). `none` inside a list is
#   an ordinary path, so a typo cannot silently discard the rest of the list, and
#   `no ne` is two paths, not the opt-out. Blank is NOT the opt-out: every layer
#   above the finder turns blank into the built-in list, and unset fails closed.
mandatory_context_is_none() {
  local _mc_v
  _mc_v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
  _mc_v="${_mc_v# }"
  _mc_v="${_mc_v% }"
  [ "$_mc_v" = "none" ]
}
