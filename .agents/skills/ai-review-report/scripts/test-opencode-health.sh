#!/bin/bash
# Offline regression tests for the OpenCode v2 `/api/info` health probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH="$SCRIPT_DIR/lib/opencode-health.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Every probe runs under `env -i` — the same isolation test-install-opencode.sh
# uses. Without it the caller's environment leaks in, and a developer with
# OPENCODE_CONFIG exported saw the suite abort on its FIRST nominal-success
# case: the inherited value activates the binding check while the stub emits no
# config source, so the script correctly exits 3 and the test reads as a broken
# gate rather than a leaky harness.
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
  exit "${STUB_CONFIG_RC:-0}"
fi
[ "${1:-}" = api ] && [ "${2:-}" = get ] && [ "${3:-}" = /api/info ] || exit 64
if [ -n "${STUB_IGNORE_TERM:-}" ]; then trap '' TERM INT; fi
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
printf '%s\n' "${STUB_PAYLOAD:-{\"version\":\"2.0.11\",\"pid\":42}}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/opencode"

: > "$TMP/calls"
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/success.out"
grep -qx 'api get /api/info' "$TMP/calls" || fail "probe did not use the supported v2 API command"
grep -q 'service healthy' "$TMP/success.out" || fail "valid /api/info payload was not accepted"
ok "valid v2 /api/info payload passes"

if env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_PAYLOAD='<html>not health json</html>' OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 \
  bash "$HEALTH" > "$TMP/invalid.out" 2>&1; then
  fail "non-JSON payload unexpectedly passed"
fi
grep -q 'invalid payload' "$TMP/invalid.out" || fail "invalid payload failure was not actionable"
ok "HTML/non-info payload fails"

if env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
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

env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"$MANAGED\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/bound.out" \
  || fail "a service bound to the managed config was rejected"
grep -q 'service healthy' "$TMP/bound.out" || fail "bound run did not report healthy"
ok "service bound to the managed config passes"

_health_rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"/home/dev/.config/opencode/opencode.json\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/unbound.out" 2>&1 || _health_rc=$?
[ "$_health_rc" -eq 3 ] \
  || fail "a foreign-config binding must exit 3 (fatal everywhere), got $_health_rc"
grep -q 'opencode service stop' "$TMP/unbound.out" \
  || fail "foreign-config failure did not name the fix"
ok "service bound to a foreign config exits 3 with an actionable fix"

# "Cannot verify" is treated exactly like "wrong", and for the same reason: a
# caller cannot tell the difference from the outcome, and continuing means
# reviewing under an unknown provider and permission policy. Exit 3, not 1 —
# exit 1 is advisory in CI, which would re-open the hole for this path only.
_health_rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/nocfg.out" 2>&1 || _health_rc=$?
[ "$_health_rc" -eq 3 ] \
  || fail "an unverifiable binding must exit 3, not degrade to a pass (got $_health_rc)"
grep -q 'Could not verify' "$TMP/nocfg.out" \
  || fail "the unverifiable-binding failure did not distinguish itself from a foreign binding"
ok "an unverifiable binding fails closed and is distinguishable from a foreign one"

# The split is the whole point: a liveness blip must stay advisory (exit 1) so
# CI's non-blocking treatment of LADR-028 survives, while 3 stays fatal.
_health_rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_PAYLOAD='<html>not health json</html>' OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 \
  bash "$HEALTH" > "$TMP/live.out" 2>&1 || _health_rc=$?
[ "$_health_rc" -eq 1 ] \
  || fail "a liveness failure must stay advisory (exit 1), got $_health_rc"
ok "a liveness failure stays exit 1 (advisory) and never borrows the fatal code"

env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"/somewhere/else.json\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/unset.out" \
  || fail "an unset OPENCODE_CONFIG must skip the binding check"
ok "unset OPENCODE_CONFIG skips the binding check"

# --- A liveness failure must not smuggle the binding check past us ----------
# The liveness result used to `exit 1` immediately, which skipped the binding
# check entirely — and exit 1 is advisory in CI, so one flaky /api/info probe
# was enough for CI to proceed with the managed config never verified. Liveness
# is now recorded and the binding question is asked regardless.
_health_rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" STUB_RC=1 \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"/home/dev/.config/opencode/opencode.json\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/live_fail_foreign.out" 2>&1 || _health_rc=$?
[ "$_health_rc" -eq 3 ] \
  || fail "a foreign binding must still be fatal when liveness also failed (got $_health_rc)"
ok "a liveness failure no longer bypasses a foreign-binding detection"

# The converse must stay true, or every blip becomes a hard abort and LADR-028's
# deliberate non-blocking stance is gone: service not answering AND binding
# unreadable is ONE fault, already reported, and the run fails at its first
# model call anyway.
_health_rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" STUB_RC=1 \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/live_fail_unread.out" 2>&1 || _health_rc=$?
[ "$_health_rc" -eq 1 ] \
  || fail "service-down plus unreadable binding must stay advisory, not fatal (got $_health_rc)"
grep -q 'one fault, not two' "$TMP/live_fail_unread.out" \
  || fail "the single-fault case was not explained"
ok "service-down plus unreadable binding stays advisory (LADR-028 preserved)"

# --- A wedged probe that ignores SIGTERM must still be bounded -------------
# `kill` + `wait` is not a bound: a process that ignores SIGTERM leaves `wait`
# blocked forever, so the timeout becomes a no-op and the caller hangs instead
# of failing — the opposite of the intent, since "opencode is wedged" is
# exactly the condition the probe exists to detect. SIGKILL escalation after a
# short grace is what makes the deadline real. This case hangs forever if the
# escalation is removed, so it is also its own mutation test.
_health_rc=0
_t0=$(date +%s)
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  STUB_IGNORE_TERM=1 STUB_SLEEP=120 OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=2 \
  bash "$HEALTH" > "$TMP/wedged.out" 2>&1 || _health_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
[ "$_health_rc" -ne 0 ] || fail "a wedged probe was reported healthy"
[ "$_elapsed" -lt 30 ] \
  || fail "the probe was not bounded — took ${_elapsed}s against a 2s timeout (SIGTERM ignored, no SIGKILL escalation?)"
ok "a probe ignoring SIGTERM is still killed and bounded (${_elapsed}s)"

# --- A path that merely CONTAINS the managed path is a foreign binding -------
# The check was `grep -F` on the managed path, which is a substring test: a
# service bound to `<managed>.bak`, or to a sibling run's config nested under a
# longer path, passed as bound. Exact membership is required. Both branches of
# the helper are exercised: with jq on PATH and with jq hidden.
# The with-jq iteration is only a test of the jq branch when jq is actually
# present: on a jq-less machine both iterations would exercise the fallback
# and the suite would still report both branches green (review 5266102870,
# finding 2). Require it, as test-check-versions.sh does.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to exercise the with-jq binding branch (install jq, or run on ubuntu-latest where it is preinstalled)"
for _jq_mode in with-jq without-jq; do
  # "Without jq" is a PATH holding everything the system has EXCEPT jq — the
  # script still needs grep, sed, timeout and friends — so the non-jq branch
  # really runs rather than the whole script dying with 127.
  _path="$TMP/bin:/usr/bin:/bin"
  if [ "$_jq_mode" = without-jq ]; then
    if [ ! -d "$TMP/nojq" ]; then
      mkdir -p "$TMP/nojq"
      for _t in /usr/bin/* /bin/*; do
        _n="$(basename "$_t")"
        [ "$_n" = jq ] && continue
        [ -e "$TMP/nojq/$_n" ] || ln -s "$_t" "$TMP/nojq/$_n" 2>/dev/null || true
      done
    fi
    _path="$TMP/bin:$TMP/nojq"
  fi
  _health_rc=0
  env -i PATH="$_path" STUB_CALL_LOG="$TMP/calls" \
    OPENCODE_CONFIG="$MANAGED" \
    STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"${MANAGED}.bak\"}]" \
    OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/substr-$_jq_mode.out" 2>&1 || _health_rc=$?
  [ "$_health_rc" -eq 3 ] \
    || fail "($_jq_mode) a bound path that merely contains the managed path must be a foreign binding (got $_health_rc)"
  _health_rc=0
  env -i PATH="$_path" STUB_CALL_LOG="$TMP/calls" \
    OPENCODE_CONFIG="$MANAGED" \
    STUB_CONFIG_SOURCES="[{\"type\":\"env\"},{\"type\":\"document\",\"path\":\"$MANAGED\"}]" \
    OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/exact-$_jq_mode.out" 2>&1 || _health_rc=$?
  [ "$_health_rc" -eq 0 ] \
    || fail "($_jq_mode) the exact managed path among other sources must still pass (got $_health_rc)"
done
ok "binding requires the exact managed path, not a substring (with and without jq)"

# --- A FAILED config inspection is not a passed binding check ---------------
# `opencode debug config` can write part of its output — including the managed
# path — and then exit non-zero. Matching that partial document would pass the
# gate on an inspection that did not succeed, which is the same false-OK the
# binding check exists to close.
_health_rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_CALL_LOG="$TMP/calls" \
  OPENCODE_CONFIG="$MANAGED" STUB_CONFIG_RC=1 \
  STUB_CONFIG_SOURCES="[{\"type\":\"document\",\"path\":\"$MANAGED\"}]" \
  OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT=3 bash "$HEALTH" > "$TMP/cfgfail.out" 2>&1 || _health_rc=$?
[ "$_health_rc" -eq 3 ] \
  || fail "a failed 'debug config' that still printed the managed path must not pass the binding gate (got $_health_rc)"
ok "a failed config inspection is treated as unverified, not as a pass"

echo "All $pass opencode-health tests passed"
