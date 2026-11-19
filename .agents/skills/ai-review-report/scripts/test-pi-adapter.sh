#!/bin/bash
# L1: the pi backend honours the run contract, the per-attempt environment,
# stdin identity, exit mapping and the initialize checks (LADR-128).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HELPER="$SCRIPT_DIR/lib/opencode-with-fallback.sh"
INIT="$SCRIPT_DIR/lib/backend-initialize.sh"
POLICY="$REPO_ROOT/.agents/skills/ai-review-report/assets/pi/policy.js"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/agent"
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
ok() { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

cat > "$BIN/pi" <<PI
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
env | sort > "$TMP/env.\$\$.log"
cat > "$TMP/stdin.log"
_scenario="$(cat "$TMP/scenario" 2>/dev/null || echo ok)"
if [ "\$_scenario" = "fail" ]; then exit 1; fi
if [ "\$_scenario" = "empty" ]; then exit 0; fi
cat "$TMP/response.md"
PI
chmod +x "$BIN/pi"

printf '## Primary prompt\nreview this\n' > "$TMP/prompt.md"
printf '## Response\n%s\n' "$(head -c 320 /dev/zero | tr '\0' 'x')" > "$TMP/response.md"

run_helper() { # run_helper <primary> <fb1> <fb2> <env...>
  local _p="$1" _f1="$2" _f2="$3"; shift 3
  rm -f "$TMP/argv.log" "$TMP/stdin.log" "$TMP"/env.*.log
  ( cd "$TMP" && \
    PATH="$BIN:/usr/bin:/bin" \
    OPENCODE_REVIEW_REPORT_BACKEND=pi \
    OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai \
    OPENCODE_AGENT=review \
    PI_CODING_AGENT_DIR="$TMP/agent" \
    OPENCODE_OPENAI_API_KEY=key-openai \
    OPENCODE_ANTHROPIC_API_KEY=key-anthropic \
    GITHUB_TOKEN=gh-token \
    GH_TOKEN=gh-token \
    "$@" \
    bash "$HELPER" "$_p" "$_f1" "$_f2" -- "$TMP/prompt.md" > "$TMP/out.txt" 2>"$TMP/err.txt" )
}

echo "=========================================="
echo "Testing pi review adapter (LADR-128)"
echo "=========================================="

run_helper primary-model "" ""
rc=$?
check "a successful pi attempt exits 0" "0" "$rc"
grep -q -- '--print --no-session --no-approve -nc -ns -np --no-mcp -ne' "$TMP/argv.log" \
  && ok "the isolation flags are present" || bad "isolation flags missing: $(cat "$TMP/argv.log")"
grep -qF -- "assets/pi/policy.js" "$TMP/argv.log" && ok "the pinned policy extension is loaded" || bad "policy extension not passed"
grep -q -- '--model openai/primary-model' "$TMP/argv.log" && ok "the model target is parsed" || bad "model target wrong"
grep -q -- '--append-system-prompt' "$TMP/argv.log" && ok "native context is supplied explicitly" || bad "native context flag missing"

check "stdin bytes equal the prompt" "$(sha256sum "$TMP/prompt.md" | cut -d' ' -f1)" "$(sha256sum "$TMP/stdin.log" | cut -d' ' -f1)"
envlog="$(ls -t "$TMP"/env.*.log 2>/dev/null | head -1)"
[ -n "$envlog" ] && ok "the attempt environment was captured" || bad "no environment capture"
grep -q '^OPENCODE_OPENAI_API_KEY=key-openai$' "$envlog" && ok "the attempt carries its provider key" || bad "provider key missing"
grep -q '^GITHUB_TOKEN=' "$envlog" && bad "GITHUB_TOKEN reached the pi child" || ok "GITHUB_TOKEN is stripped"
grep -q '^GH_TOKEN=' "$envlog" && bad "GH_TOKEN reached the pi child" || ok "GH_TOKEN is stripped"
grep -q '^OPENCODE_ANTHROPIC_API_KEY=' "$envlog" && bad "another provider key reached the pi child" || ok "only one provider key is present"
grep -q '^PI_CODING_AGENT_DIR=' "$envlog" && ok "the prepared agent directory is exported" || bad "PI_CODING_AGENT_DIR missing"
grep -q '^PI_ROLE=review$' "$envlog" && ok "the review role is set" || bad "PI_ROLE missing"

# Two-provider chain: the second attempt carries the second provider's key.
( cd "$TMP" && PATH="$BIN:/usr/bin:/bin" OPENCODE_REVIEW_REPORT_BACKEND=pi \
  OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_AGENT=analyse PI_CODING_AGENT_DIR="$TMP/agent" \
  OPENCODE_OPENAI_API_KEY=k1 OPENCODE_ANTHROPIC_API_KEY=k2 \
  bash "$HELPER" anthropic/alt-model "" "" -- "$TMP/prompt.md" >/dev/null 2>&1 )
env2="$(ls -t "$TMP"/env.*.log 2>/dev/null | head -1)"
grep -q '^OPENCODE_ANTHROPIC_API_KEY=k2$' "$env2" && ok "a chain attempt carries its own provider key" || bad "chain key mapping wrong"
grep -q '^OPENCODE_OPENAI_API_KEY=' "$env2" && bad "the wrong provider key reached the chain attempt" || ok "the chain attempt holds exactly one key"

# Exit mapping: a non-zero attempt falls through to the next model.
cat > "$BIN/pi" <<PI
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
cat > "$TMP/stdin.log"
case "\$*" in *secondary-model*) cat "$TMP/response.md"; exit 0 ;; *) exit 1 ;; esac
PI
chmod +x "$BIN/pi"
run_helper primary-model secondary-model ""
rc=$?
check "a non-zero attempt falls through and the second succeeds" "0" "$rc"
check "both models were attempted" "2" "$(grep -c '^--print' "$TMP/argv.log")"
grep -q -- '--model openai/secondary-model' "$TMP/argv.log" && ok "the fallback model was tried" || bad "fallback model missing"

# Empty output is a failure, never a hollow success.
cat > "$BIN/pi" <<PI
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
cat > "$TMP/stdin.log"
exit 0
PI
chmod +x "$BIN/pi"
run_helper primary-model "" ""
rc=$?
check "empty output is rejected" "1" "$rc"

# Probe isolation (LADR-128): the pi probe carries one key and loads the policy.
cat > "$BIN/pi" <<PI
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
env | sort > "$TMP/env.\$\$.log"
echo OK
PI
chmod +x "$BIN/pi"
rm -f "$TMP/argv.log" "$TMP"/env.*.log
( cd "$TMP" && PATH="$BIN:/usr/bin:/bin" PI_CODING_AGENT_DIR="$TMP/agent" \
  OPENCODE_CONFIG="$TMP/oc.json" OPENCODE_OPENAI_API_KEY=key-openai OPENCODE_ANTHROPIC_API_KEY=key-anthropic \
  GITHUB_TOKEN=gh-token bash -c '. "$1"; backend_probe pi openai primary-model' _ "$SCRIPT_DIR/lib/backend-probe.sh" >/dev/null 2>&1 )
probe_env="$(ls -t "$TMP"/env.*.log 2>/dev/null | head -1)"
grep -q -- '-e .*assets/pi/policy.js' "$TMP/argv.log" && ok "the probe loads the policy extension" || bad "the probe skipped the policy extension"
grep -q '^OPENCODE_OPENAI_API_KEY=key-openai$' "$probe_env" && ok "the probe carries its provider key" || bad "the probe lost its provider key"
grep -q '^GITHUB_TOKEN=' "$probe_env" && bad "the probe leaked GITHUB_TOKEN" || ok "the probe strips GITHUB_TOKEN"

# Initialize: version mismatch, missing directory, not-ready auth, missing model.
init_case() { # init_case <env assignment...>
  (
    export PATH="$BIN:/usr/bin:/bin" PI_CODING_AGENT_DIR="$TMP/agent"
    export OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=gpt-5.4
    for _kv in "$@"; do export "$_kv"; done
    bash "$INIT" pi "$SCRIPT_DIR/lib" >/dev/null 2>&1
  ); echo $?
}
cat > "$BIN/pi" <<'PI'
#!/bin/bash
case "$1" in
  --version) echo "${PI_VERSION:-1.5.2}"; exit 0 ;;
  auth) echo "${PI_AUTH:-ready}"; exit 0 ;;
esac
exit 0
PI
chmod +x "$BIN/pi"
printf '{"providers":{"openai":{"models":[{"id":"gpt-5.4"}]}}}\n' > "$TMP/agent/models.json"

check "initialize passes with a matching pin and ready auth" "0" "$(init_case OPENCODE_TOOL_PI_VERSION=1.5.2)"
check "initialize fails on a version mismatch" "3" "$(init_case OPENCODE_TOOL_PI_VERSION=1.4.0)"
check "initialize fails without a prepared directory" "3" "$(init_case PI_CODING_AGENT_DIR= OPENCODE_TOOL_PI_VERSION=1.5.2)"
check "initialize fails when auth is not ready" "3" "$(init_case PI_AUTH=not_ready OPENCODE_TOOL_PI_VERSION=1.5.2)"
check "initialize fails when a requested model is absent" "3" "$(init_case OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=absent OPENCODE_TOOL_PI_VERSION=1.5.2)"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All pi-adapter tests passed"; else echo "$fail pi-adapter test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
