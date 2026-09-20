#!/bin/bash
# opencode-health.sh — provider-agnostic health check via the opencode v2 CLI.
#
# OpenCode v2 starts an authenticated service and no longer exposes the v1
# unauthenticated `/global/health` contract. Its supported diagnostic is:
#   opencode api get /api/info
# The CLI discovers the service and handles its generated credentials, then
# prints JSON containing at least `version` and `pid`. No per-provider URL/auth
# derivation is required.
#
# NOTE: /api/info reports that opencode itself is up — it does NOT prove the
# upstream model gateway is reachable or the API key valid. The real functional
# check remains the "Assert Review Model Selection Works" step (CI) / the chunk
# run (local), which makes an actual model call.
#
# Requires opencode on PATH and its provider config already prepared.
#
# Optional env:
#   OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT  seconds to wait for the API info probe (default 30)
#
# Exit status is deliberately three-valued, because the two things this script
# checks carry different consequences:
#   0  opencode is up AND (when OPENCODE_CONFIG is set) the managed config is
#      confirmed to be the one actually loaded.
#   1  liveness problem — /api/info did not answer, timed out, or returned a
#      payload that is not an info document. ADVISORY: it says nothing about
#      review correctness, so CI logs it and proceeds (LADR-028's deliberate
#      choice), while the local preflight aborts.
#   3  the managed config is NOT confirmed — either the service is bound to a
#      different config, or the binding could not be read at all. FATAL
#      EVERYWHERE, including CI. Unlike a liveness blip this has a direct,
#      silent effect on the review: the wrong provider and model ids, and no
#      LADR-029 permission lockdown on untrusted PR code, with nothing in the
#      posted output to say so.
# A caller that treats every non-zero the same turns 3 back into a log line —
# which is exactly the hole this split exists to close, so check for 3
# explicitly rather than inverting the test.

set -u

TIMEOUT="${OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT:-30}"
OUT="/tmp/opencode-health.$$.out"
LOG="/tmp/opencode-health.$$.log"
CFG="/tmp/opencode-health.$$.cfg"

if ! command -v opencode >/dev/null 2>&1; then
  echo "❌ opencode CLI not found on PATH — install it before the health check." >&2
  exit 1
fi

# Disable Claude Code (.claude) support to avoid conflicts with opencode.
# OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE can override the value (default 1).
export OPENCODE_DISABLE_CLAUDE_CODE="${OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE:-1}"

# Run the supported v2 diagnostic in the background so a wedged service remains
# bounded without relying on GNU `timeout` (local runs may be on macOS).
opencode api get /api/info >"$OUT" 2>"$LOG" &
_api_pid=$!
trap '[ -n "${_api_pid:-}" ] && kill "$_api_pid" 2>/dev/null; wait "$_api_pid" 2>/dev/null || true; rm -f "$LOG" "$OUT" "$CFG" 2>/dev/null || true' EXIT

DEADLINE=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  kill -0 "$_api_pid" 2>/dev/null || break
  sleep 1
done

# Liveness is RECORDED, not acted on yet. Exiting here would skip the binding
# check below, and a liveness failure is advisory in CI — so a blip used to be
# enough to make CI proceed with the managed config never verified at all,
# which is the hole the binding check exists to close. Whatever the probe says,
# the binding question still gets asked.
_live_rc=0
if kill -0 "$_api_pid" 2>/dev/null; then
  kill "$_api_pid" 2>/dev/null || true
  wait "$_api_pid" 2>/dev/null || true
  _api_pid=""
  echo "⚠️ opencode v2 API info probe timed out after ${TIMEOUT}s." >&2
  tail -n 20 "$LOG" >&2 2>/dev/null || true
  _live_rc=1
else
  _api_rc=0
  wait "$_api_pid" || _api_rc=$?
  _api_pid=""
  if [ "$_api_rc" -ne 0 ]; then
    echo "⚠️ opencode v2 API info probe failed (exit ${_api_rc})." >&2
    tail -n 20 "$LOG" >&2 2>/dev/null || true
    _live_rc=1
  fi
fi

if [ "$_live_rc" -eq 0 ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.version | type == "string" and length > 0) and (.pid | type == "number")' "$OUT" >/dev/null 2>&1 || {
      echo "⚠️ opencode v2 API info probe returned an invalid payload." >&2
      tail -n 20 "$OUT" >&2 2>/dev/null || true
      _live_rc=1
    }
  else
    grep -q '"version"[[:space:]]*:' "$OUT" 2>/dev/null && \
      grep -q '"pid"[[:space:]]*:' "$OUT" 2>/dev/null || {
        echo "⚠️ opencode v2 API info probe returned an invalid payload." >&2
        tail -n 20 "$OUT" >&2 2>/dev/null || true
        _live_rc=1
      }
  fi
fi

if [ "$_live_rc" -eq 0 ] && [ ! -s "$OUT" ]; then
  echo "⚠️ opencode v2 API info probe returned no data." >&2
  _live_rc=1
fi

# A v2 background service resolves its config ONCE, from the environment of
# whichever client started it. A later client's OPENCODE_CONFIG is ignored in
# silence — verified on 2.0.11: with a service already up from config A,
# `OPENCODE_CONFIG=B opencode debug config` still reports A. In CI the runner
# is fresh so our own process starts the service and the binding is ours; on a
# developer box a running session owns it, and then the managed config
# (LADR-071) is simply NOT in effect — wrong provider/models, and the review
# agent's permission lockdown (LADR-029) silently absent. That is the LADR-053
# false-OK shape, so check the binding rather than assume it.
#
# "Could not read the binding" is treated exactly like "the binding is wrong",
# and both exit 3. This used to degrade to no check, on the reasoning that a
# false alarm was worse than a missed one. That was backwards: `debug config`
# is a documented v2 command and install-opencode.sh now guarantees a major
# >= 2, so an empty read means something is genuinely wrong — while the cost
# of the two outcomes is not symmetric at all. A false alarm is a loud message
# naming the exact command to run; a false pass is a review that silently ran
# under someone else's provider with the permission lockdown absent. Fail
# closed, and say which of the two cases fired so a future opencode that drops
# `debug config` is diagnosable in one read rather than looking like a stale
# service. Bounded with the same background+deadline idiom as the probe above
# (no GNU `timeout` on macOS).
if [ -n "${OPENCODE_CONFIG:-}" ]; then
  : > "$CFG"
  opencode debug config >"$CFG" 2>/dev/null &
  _cfg_pid=$!
  _cfg_deadline=$((SECONDS + TIMEOUT))
  while [ "$SECONDS" -lt "$_cfg_deadline" ]; do
    kill -0 "$_cfg_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$_cfg_pid" 2>/dev/null; then
    kill "$_cfg_pid" 2>/dev/null || true
    : > "$CFG"
  fi
  wait "$_cfg_pid" 2>/dev/null || true
  if [ ! -s "$CFG" ] && [ "$_live_rc" -ne 0 ]; then
    # Unverifiable AND the service is not answering: one fault, already
    # reported. Calling this a config mismatch would turn every liveness blip
    # into a hard abort, which is exactly what LADR-028 chose not to do — and
    # the run will fail at its first model call anyway if opencode is really
    # down. Stay advisory.
    echo "⚠️ Binding not verified either — the service is not answering, so this is one fault, not two." >&2
  elif [ ! -s "$CFG" ]; then
    echo "❌ Could not verify which config opencode is using — 'opencode debug config' returned nothing." >&2
    echo "    OPENCODE_CONFIG=${OPENCODE_CONFIG}" >&2
    echo "    Unverified is treated as unbound: continuing risks reviewing under a foreign provider, model chain and permission policy with nothing in the output to say so." >&2
    echo "    Usual cause is a wedged service — 'opencode service stop', then start this review again." >&2
    echo "    If the command itself is gone from this opencode build, that is a toolchain break, not a stale service." >&2
    exit 3
  elif ! grep -qF "$OPENCODE_CONFIG" "$CFG"; then
    echo "❌ opencode is NOT using the managed config for this run." >&2
    echo "    OPENCODE_CONFIG=${OPENCODE_CONFIG}" >&2
    echo "    A v2 background service binds its config when it starts, so an already-running service ignores this value." >&2
    echo "    Without it the selected provider, model ids and the review agent's permission lockdown are all absent." >&2
    echo "    Fix: run 'opencode service stop', then start this review again." >&2
    exit 3
  fi
fi

# Binding is settled (or deliberately not asserted). Only now does the recorded
# liveness result decide the advisory exit.
if [ "$_live_rc" -ne 0 ]; then
  exit 1
fi
echo "✓ opencode v2 service healthy (/api/info)"
exit 0
