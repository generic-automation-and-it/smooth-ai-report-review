#!/bin/bash
set -e

# Test script for lib/quarantine-project-config.sh (LADR-103).
# The gate stands its managed opencode config in place of the repo-under-
# review's own opencode.json(c) files for the duration of the run, so newer
# opencode builds' "untrusted project OpenCode config is not allowed in CI"
# hard-fail never fires and a PR-head config cannot override the review
# agent's permission lockdown. Restore must be total: local-review.sh runs on
# the user's live repo and pipeline-ai-analyse.yml commits the tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/quarantine-project-config.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---"; printf '%s\n' "$actual"
    fail=$((fail + 1))
  fi
}

MANAGED="$TMP_DIR/managed.json"
printf '{"managed":true}\n' > "$MANAGED"
export OPENCODE_CONFIG="$MANAGED"

# --- Case 1: regular files are moved aside and replaced with managed content
ws="$TMP_DIR/ws1"; mkdir -p "$ws/.opencode"
printf '{"user":"root"}\n' > "$ws/opencode.json"
printf '{"user":"dot"}' > "$ws/.opencode/opencode.jsonc"
quarantine_project_config "$ws" >/dev/null
check "Case 1: nested original held aside" "" "$(ls "$ws/.opencode/opencode.jsonc" 2>/dev/null || true)"
check "Case 1: replacement carries managed content" '{"managed":true}' "$(cat "$ws/opencode.json")"
check "Case 1: manifest lists both" "opencode.json .opencode/opencode.jsonc " "$QPC_QUARANTINED"
restore_project_config >/dev/null
check "Case 1: root original restored" '{"user":"root"}' "$(cat "$ws/opencode.json")"
check "Case 1: .opencode original restored" '{"user":"dot"}' "$(cat "$ws/.opencode/opencode.jsonc")"

# --- Case 2: root symlink (LEGO layout) moves as a link, target untouched
ws="$TMP_DIR/ws2"; mkdir -p "$ws/.github/assets"
printf '{"client":"custom"}\n' > "$ws/.github/assets/opencode.json"
ln -s ".github/assets/opencode.json" "$ws/opencode.json"
quarantine_project_config "$ws" >/dev/null
check "Case 2: replacement is a regular file, not a link" "file" "$([ -L "$ws/opencode.json" ] && echo link || echo file)"
check "Case 2: link target file untouched" '{"client":"custom"}' "$(cat "$ws/.github/assets/opencode.json")"
restore_project_config >/dev/null
check "Case 2: symlink restored as symlink" "link" "$([ -L "$ws/opencode.json" ] && echo link || echo file)"
check "Case 2: symlink target preserved" ".github/assets/opencode.json" "$(readlink "$ws/opencode.json")"

# --- Case 3: dangling symlink is quarantined and restored, not followed
ws="$TMP_DIR/ws3"; mkdir -p "$ws"
ln -s "nowhere/opencode.json" "$ws/opencode.jsonc"
quarantine_project_config "$ws" >/dev/null
check "Case 3: replacement written despite dangling link" '{"managed":true}' "$(cat "$ws/opencode.json")"
restore_project_config >/dev/null
check "Case 3: dangling link restored" "link" "$([ -L "$ws/opencode.jsonc" ] && echo link || echo file)"
check "Case 3: no leftover replacement" "absent" "$([ -e "$ws/opencode.json" ] && echo present || echo absent)"

# --- Case 4: clean tree is byte-untouched (no replacement invented)
ws="$TMP_DIR/ws4"; mkdir -p "$ws"
quarantine_project_config "$ws" >/dev/null
check "Case 4: no replacement created" "absent" "$([ -e "$ws/opencode.json" ] && echo present || echo absent)"
restore_project_config >/dev/null
check "Case 4: restore no-op exit" "0" "$?"

# --- Case 5: OPENCODE_CONFIG unset — still moves aside, warns, exit 0
ws="$TMP_DIR/ws5"; mkdir -p "$ws"
printf '{"user":1}\n' > "$ws/opencode.json"
OPENCODE_CONFIG="" quarantine_project_config "$ws" >/dev/null 2>&1
check "Case 5: quarantine exit" "0" "$?"
check "Case 5: file held with no stand-in" "absent" "$([ -e "$ws/opencode.json" ] && echo present || echo absent)"
restore_project_config >/dev/null
check "Case 5: original restored" '{"user":1}' "$(cat "$ws/opencode.json")"

# --- Case 6: restore is idempotent
restore_project_config >/dev/null
check "Case 6: second restore exit" "0" "$?"
restore_project_config "/nonexistent/manifest" >/dev/null
check "Case 6: bad manifest exit" "0" "$?"

# --- Case 7: occupant that changed mid-run is preserved, never destroyed
ws="$TMP_DIR/ws7"; mkdir -p "$ws"
printf '{"user":"orig"}\n' > "$ws/opencode.json"
quarantine_project_config "$ws" >/dev/null
held_dir="$(dirname "$QPC_MANIFEST")/occupied"
printf '{"model":"edited"}\n' > "$ws/opencode.json"
restore_project_config >/dev/null 2>&1
check "Case 7: original restored over changed occupant" '{"user":"orig"}' "$(cat "$ws/opencode.json")"
check "Case 7: occupant preserved" '{"model":"edited"}' "$(cat "$held_dir/opencode.json")"

# --- Case 8: non-file candidate (directory) is left alone
ws="$TMP_DIR/ws8"; mkdir -p "$ws/opencode.json"
quarantine_project_config "$ws" >/dev/null 2>&1
check "Case 8: directory untouched" "dir" "$([ -d "$ws/opencode.json" ] && echo dir || echo gone)"

# --- Case 9: CLI --restore works off the exported manifest (YAML steps)
ws="$TMP_DIR/ws9"; mkdir -p "$ws"
printf '{"user":9}\n' > "$ws/opencode.json"
quarantine_project_config "$ws" >/dev/null
saved_manifest="$QPC_MANIFEST"
QPC_MANIFEST="" bash "$SCRIPT_DIR/lib/quarantine-project-config.sh" --restore >/dev/null
check "Case 9: CLI restore exit" "0" "$?"
QPC_MANIFEST="$saved_manifest" restore_project_config >/dev/null
check "Case 9: original restored via manifest" '{"user":9}' "$(cat "$ws/opencode.json")"

# --- Case 10: sourced lib keeps caller state (LADR-071 sourced-lib rule)
# The vacuous form (comparing a var to itself) would pass on an empty lib —
# assert the real properties instead: candidates live in function-locals
# (no file-scope leak that could shadow a caller's SCRIPT_DIR-class var),
# and the public contract is defined.
_leak="clean"
declare -p _QPC_CANDIDATES >/dev/null 2>&1 && _leak="leaked"
check "Case 10: no file-scope state leaks into caller" "clean" "$_leak"
check "Case 10: public contract defined" "defined" "$([ "$(command -v quarantine_project_config)" = "quarantine_project_config" ] && [ "$(command -v restore_project_config)" = "restore_project_config" ] && echo defined || echo missing)"
unset _leak

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ]
