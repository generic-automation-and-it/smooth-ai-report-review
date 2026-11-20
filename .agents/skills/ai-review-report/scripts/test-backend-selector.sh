#!/bin/bash
# L0: the backend selector accepts exactly one value and never falls back.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/backend-selector.sh"

pass=0; fail=0
check() { # check <label> <expected> <actual>
  if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass + 1));
  else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi
}

echo "=========================================="
echo "Testing backend selector (LADR-124)"
echo "=========================================="

. "$LIB"

check "unset selector resolves to opencode" "opencode" "$(unset OPENCODE_REVIEW_REPORT_BACKEND; resolve_backend)"
check "blank selector resolves to opencode" "opencode" "$(OPENCODE_REVIEW_REPORT_BACKEND='' resolve_backend)"
check "explicit opencode resolves to opencode" "opencode" "$(OPENCODE_REVIEW_REPORT_BACKEND=opencode resolve_backend)"
check "display name for opencode" "OpenCode" "$(backend_display_name opencode)"
check "home URL for opencode" "https://opencode.ai" "$(backend_home_url opencode)"

for bad in OpenCode PI pi x opencode2; do
  out="$(OPENCODE_REVIEW_REPORT_BACKEND="$bad" resolve_backend 2>&1)"; rc=$?
  check "selector '$bad' is rejected" "1" "$rc"
  check "selector '$bad' names the accepted values" "1" "$(printf '%s' "$out" | grep -c 'accepted values: opencode')"
done

# Sourcing must not clobber the caller's file-scope variables.
SCRIPT_DIR_BEFORE="$SCRIPT_DIR"
REPO_ROOT="$SCRIPT_DIR/../../.."
. "$LIB"
check "sourcing leaves SCRIPT_DIR unchanged" "$SCRIPT_DIR_BEFORE" "$SCRIPT_DIR"
check "sourcing leaves REPO_ROOT unchanged" "$SCRIPT_DIR/../../.." "$REPO_ROOT"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All backend-selector tests passed"; else echo "$fail backend-selector test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
