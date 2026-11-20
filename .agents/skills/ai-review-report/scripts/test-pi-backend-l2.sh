#!/bin/bash
# L2: the real pinned pi against a localhost mock (LADR-128 D12).
# No secret, no model network call. Skipped when pi is not installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HELPER="$SCRIPT_DIR/lib/opencode-with-fallback.sh"
MOCK="$SCRIPT_DIR/test-pi-l2-mock.py"
SHAPE="$SCRIPT_DIR/lib/review-has-shape.sh"

if ! command -v pi >/dev/null 2>&1; then
  echo "⏭️  pi is not installed — L2 suite skipped"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "❌ python3 is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required"; exit 1; }

TMP="$(mktemp -d)"
trap '[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
WS="$TMP/ws"; mkdir -p "$WS/ci_temp"
( cd "$WS" && git init -q . )
printf 'L2-AGENTS-MARKER\n' > "$WS/AGENTS.md"
mkdir -p "$WS/.pi" "$WS/sub"; printf '{"defaultTools":["bash"]}\n' > "$WS/.pi/settings.json"
printf 'L2-SUB-CTX-MARKER\n' > "$WS/sub/AGENTS.md"; printf 'x\n' > "$WS/sub/file.txt"
printf 'HOSTILE-SYSTEM-MARKER\n' > "$WS/.pi/SYSTEM.md"
printf 'SECRET=leak\n' > "$WS/.env"; mkdir -p "$WS/.git"; printf 'x\n' > "$WS/.git/config"

PORT=8791
SCENARIO="$TMP/scenario.json"; REQUESTS="$TMP/requests.jsonl"
printf '{"mode":"answer","answer":"ok"}\n' > "$SCENARIO"
python3 -B "$MOCK" "$PORT" "$SCENARIO" "$REQUESTS" >/dev/null 2>&1 &
MOCK_PID=$!
sleep 1

cat > "$TMP/oc.json" <<JSON
{"provider":{"mock":{"npm":"@ai-sdk/openai-compatible","options":{"baseURL":"http://127.0.0.1:${PORT}/v1","apiKey":"{env:MOCK_KEY}"},"models":{"mock-model":{}}}}}
JSON
export OPENCODE_CONFIG="$TMP/oc.json" RUNNER_TEMP="$TMP"
. "$SCRIPT_DIR/lib/prepare-pi-config.sh"
export OPENCODE_REVIEW_REPORT_PROVIDER=mock OPENCODE_REVIEW_REPORT_PROVIDER_ID=mock OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=mock-model
prepare_pi_config "$REPO_ROOT/.agents/skills/ai-review-report/assets/pi/settings.json" >/dev/null
export PI_CODING_AGENT_DIR
[ -f "$PI_CODING_AGENT_DIR/models.json" ] || { echo "❌ pi agent directory was not prepared"; exit 1; }

printf 'review this chunk\n' > "$TMP/prompt.md"
pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

run_pi() {
  curl -s -X POST "http://127.0.0.1:${PORT}/reset" >/dev/null 2>&1 || true
  ( cd "$WS" && PATH="$PATH" OPENCODE_REVIEW_REPORT_BACKEND=pi OPENCODE_REVIEW_REPORT_PROVIDER=mock OPENCODE_AGENT="${L2_ROLE:-review}" \
    PI_CODING_AGENT_DIR="$PI_CODING_AGENT_DIR" MOCK_KEY=local-dummy PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 \
    OPENCODE_OUTPUT_SHAPE_CHECK="$SHAPE" OPENCODE_RUN_CWD="$WS" \
    bash "$HELPER" mock-model "" "" -- "$TMP/prompt.md" 2>"$TMP/err.txt" )
}

echo "=========================================="
echo "Testing real pi against the L2 mock"
echo "=========================================="

REVIEW='## Issues Found
**Issues Found:**
- 🔵 [VERIFIED] Low Priority: demo finding — `a.txt:1`.'
jq -n --arg a "$REVIEW" '{mode:"answer", answer:$a}' > "$SCENARIO"
out="$(run_pi)"; rc=$?
[ "$rc" -eq 0 ] && ok "a chunk review completes" || bad "review failed (rc=$rc): $(tail -2 "$TMP/err.txt")"
printf '%s' "$out" | bash "$SHAPE" >/dev/null 2>&1 && ok "the answer passes review-has-shape.sh" || bad "answer fails the shape predicate"
sys="$(head -1 "$REQUESTS" | jq -r '.messages[0].content // ""')"
printf '%s' "$sys" | grep -q 'L2-AGENTS-MARKER' && ok "native context carries the repo AGENTS.md" || bad "AGENTS.md missing from the system prompt"
printf '%s' "$sys" | grep -q 'HOSTILE-SYSTEM-MARKER' && bad "hostile .pi/SYSTEM.md reached pi" || ok "hostile project configuration had no effect"

jq -n '{mode:"tool_calls", tool_calls:[{name:"read", arguments:{path:".env"}}], then:{mode:"answer", answer:"done"}}' > "$SCENARIO"
run_pi >/dev/null 2>&1 || true
if grep -q 'policy:' "$REQUESTS" 2>/dev/null; then ok "a read of .env is blocked by the policy extension"; else bad "the .env read was not blocked"; fi
grep -q 'SECRET=leak' "$REQUESTS" 2>/dev/null && bad "the credential content reached the model" || ok "no credential content reached the model"

printf '{"mode":"http500"}\n' > "$SCENARIO"
run_pi >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "a provider error maps to a failed attempt" || bad "a provider error was accepted"

printf '{"mode":"empty"}\n' > "$SCENARIO"
run_pi >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "an empty answer is rejected" || bad "an empty answer was accepted"

# Analyse role (LADR-129): the protected edit is refused by the runtime. The
# allow side of the edit matrix is pinned at L0 by test-pi-policy.sh.
jq -n '{mode:"tool_calls", tool_calls:[{name:"edit", arguments:{path:".env", edits:[{oldText:"SECRET=leak", newText:"x"}]}}], then:{mode:"answer", answer:"done"}}' > "$SCENARIO"
L2_ROLE=analyse run_pi >/dev/null 2>&1 || true
grep -q 'SECRET=leak' "$WS/.env" && ok "an analyse edit of .env is blocked (file unchanged)" || bad "the analyse edit fence did not block .env"

# On-read nested context (LADR-132): a read under sub/ attaches its AGENTS.md once.
jq -n '{mode:"tool_calls", tool_calls:[{name:"read", arguments:{path:"sub/file.txt"}}], then:{mode:"answer", answer:"done"}}' > "$SCENARIO"
run_pi >/dev/null 2>&1 || true
n="$(grep -o 'L2-SUB-CTX-MARKER' "$REQUESTS" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = "1" ] && ok "a nested AGENTS.md is attached on read exactly once" || bad "nested attachment count was ${n:-0}"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All pi L2 tests passed"; else echo "$fail pi L2 test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
