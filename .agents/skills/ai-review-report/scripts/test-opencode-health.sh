#!/bin/bash
# Offline regression tests for the OpenCode v2 `/api/info` health probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH="$SCRIPT_DIR/lib/opencode-health.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "❌ $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "✅ $*"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/opencode" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_CALL_LOG"
if [ "${1:-}" = debug ] && [ "${2:-}" = config ]; then
  # Absent STUB_CONFIG_SOURCES the stub emits nothing, which the health script
  # must treat as "cannot tell" and skip — same degrade path as an opencode
  # without `debug config`.
  [ -z "${STUB_CONFIG_SOURCES:-}" ] || printf '%s\n' "$STUB_CONFIG_SOURCES"
  exit 0
fi
[ "${1:-}" = api ] && [ "${2:-}" = get ] && [ "${3:-}" = /api/info ] || exit 64
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
printf '%s\n' "${STUB_PAYLOAD:-{\"version\":\"2.0.11\",\"pid\":42}}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/opencode"

: > "$TMP/calls"
env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/success.out"
grep -qx 'api get /api/info' "$TMP/calls" || fail "probe did not use the supported v2 API command"
grep -q 'service healthy' "$TMP/success.out" || fail "valid /api/info payload was not accepted"
ok "valid v2 /api/info payload passes"

if env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_PAYLOAD='<html>not health json</html>' OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 \
  bash "$HEALTH" > "$TMP/invalid.out" 2>&1; then
  fail "non-JSON payload unexpectedly passed"
fi
grep -q 'invalid payload' "$TMP/invalid.out" || fail "invalid payload failure was not actionable"
ok "HTML/non-info payload fails"

if env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_SLEEP=3 OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=1 \
  bash "$HEALTH" > "$TMP/timeout.out" 2>&1; then
  fail "timed-out probe unexpectedly passed"
fi
grep -q 'timed out' "$TMP/timeout.out" || fail "timeout failure was not reported"
ok "wedged v2 service probe is bounded"

# --- managed-config binding (LADR-087) --------------------------------------
# A v2 background service binds its config at START time, so an already-running
# service silently ignores a later client's OPENCODE_CONFIG. The failure is
# invisible: opencode is healthy, the review just runs on somebody else's
# provider, models and permissions.
MANAGED="$TMP/opencode.resolved.json"
printf '{}\n' > "$MANAGED"

env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"$MANAGED\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/bound.out" \
  || fail "a service bound to the managed config was rejected"
grep -q 'service healthy' "$TMP/bound.out" || fail "bound run did not report healthy"
ok "service bound to the managed config passes"

if env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"/home/dev/.config/opencode/opencode.json\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/unbound.out" 2>&1; then
  fail "a service bound to a FOREIGN config silently passed"
fi
grep -q 'opencode service stop' "$TMP/unbound.out" \
  || fail "foreign-config failure did not name the fix"
ok "service bound to a foreign config fails with an actionable fix"

env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/nocfg.out" \
  || fail "an unreadable config-source list must degrade, not fail"
ok "unreadable config-source list degrades to no check"

env PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"/somewhere/else.json\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/unset.out" \
  || fail "an unset OPENCODE_CONFIG must skip the binding check"
ok "unset OPENCODE_CONFIG skips the binding check"

echo "All $pass opencode-health tests passed"
