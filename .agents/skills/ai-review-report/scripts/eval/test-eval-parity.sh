#!/bin/bash
# L1: the report-only parity section renders agreement and never changes a verdict.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/parity-report.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

printf 'must-catch|MC-001|CAUGHT|ok\nmust-not-flag|DR-001|CLEAN|ok\nmust-catch|MC-002|MISSED|detail\n' > "$TMP/pi.txt"
printf 'must-catch|MC-001|CAUGHT|ok\nmust-catch|MC-099|CAUGHT|ok\n' > "$TMP/oc-only.txt"
printf 'must-catch|MC-001|CAUGHT|ok\nmust-not-flag|DR-001|FLAGGED|detail\nmust-catch|MC-002|MISSED|detail\n' > "$TMP/oc.txt"

out="$(bash "$REPORT" "$TMP/pi.txt" "$TMP/oc.txt")"; rc=$?

echo "=========================================="
echo "Testing eval parity section (LADR-130)"
echo "=========================================="

check "the parity section exits 0 even with a difference" "0" "$rc"
check "an agreeing fixture is marked match" "1" "$(printf '%s' "$out" | grep -c 'MC-001.*match')"
check "a differing fixture is marked DIFF" "1" "$(printf '%s' "$out" | grep -c 'DR-001.*DIFF')"
check "the counts are reported" "1" "$(printf '%s' "$out" | grep -c 'match: 2 · differ: 1')"
check "the section never assigns a fail verdict" "0" "$(printf '%s' "$out" | grep -c '^.*|.*fail' || true)"
check "the section states it is measured, never gated" "1" "$(printf '%s' "$out" | grep -c 'measured, never gated')"
out="$(bash "$REPORT" "$TMP/pi.txt" "$TMP/oc-only.txt")"; rc=$?
check "an OpenCode-only fixture is reported, not dropped" "1" "$(printf '%s' "$out" | grep -c 'MC-002.*MISSED.*not-run.*DIFF')"
check "the union comparison still exits 0" "0" "$rc"

: > "$TMP/empty.txt"
out="$(bash "$REPORT" "$TMP/empty.txt" "$TMP/oc.txt")"; rc=$?
check "an empty pi run still exits 0" "0" "$rc"
check "a missing results file is reported without failing" "0" "$(bash "$REPORT" "$TMP/nope.txt" "$TMP/oc.txt" >/dev/null 2>&1; echo $?)"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All eval-parity tests passed"; else echo "$fail eval-parity test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
