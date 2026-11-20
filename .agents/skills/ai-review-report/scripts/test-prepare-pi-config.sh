#!/bin/bash
# L0/L1: the pi agent directory is derived from the resolved OpenCode config.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIB="$SCRIPT_DIR/lib/prepare-pi-config.sh"
SETTINGS="$REPO_ROOT/.agents/skills/ai-review-report/assets/pi/settings.json"

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export RUNNER_TEMP="$TMP/runner"
mkdir -p "$RUNNER_TEMP" "$TMP/ws"
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
ok() { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

echo "=========================================="
echo "Testing prepare-pi-config.sh (LADR-126)"
echo "=========================================="

cat > "$TMP/builtin.json" <<'JSON'
{
  "provider": {
    "gemini": {"npm": "@ai-sdk/google", "options": {"apiKey": "{env:OPENCODE_GEMINI_API_KEY}"}, "models": {"gemini-2.5-pro": {}}},
    "openai": {"npm": "@ai-sdk/openai", "options": {"baseURL": "https://gw.example/v1", "apiKey": "{env:OPENCODE_OPENAI_API_KEY}"}, "models": {"gpt-5.4": {}, "gpt-5.4-mini": {}}},
    "go-responses": {"npm": "@ai-sdk/openai", "options": {"baseURL": "https://zen.example/v1", "apiKey": "{env:OPENCODE_GO_OPENAI_API_KEY}"}, "models": {"gpt-5.4": {}}}
  }
}
JSON

run_prepare() { # run_prepare <cfg> <selected-provider>
  (
    export OPENCODE_CONFIG="$1"
    export OPENCODE_REVIEW_REPORT_PROVIDER_ID="$2"
    export OPENCODE_REVIEW_REPORT_MODEL_PRIMARY="gpt-5.4"
    export OPENCODE_GEMINI_API_KEY=dummy-gemini-value
    export OPENCODE_OPENAI_API_KEY=dummy-openai-value
    export OPENCODE_GO_OPENAI_API_KEY=dummy-go-value
    . "$LIB"
    prepare_pi_config "$SETTINGS" >/dev/null 2>&1
    printf '%s' "$PI_CODING_AGENT_DIR"
  )
}

dir="$(run_prepare "$TMP/builtin.json" openai)"
[ -n "$dir" ] && [ -f "$dir/models.json" ] && ok "the directory and models.json are created" || bad "no models.json"
check "provider ids match the resolved config" "gemini go-responses openai" \
  "$(jq -r '.providers | keys[]' "$dir/models.json" | sort | tr '\n' ' ' | sed 's/ $//')"
check "model ids match for openai" "gpt-5.4 gpt-5.4-mini" \
  "$(jq -r '.providers.openai.models[].id' "$dir/models.json" | sort | tr '\n' ' ' | sed 's/ $//')"
check "the injected base URL flows through" "https://gw.example/v1" \
  "$(jq -r '.providers.openai.baseUrl' "$dir/models.json")"
check "go-responses maps to openai-responses" "openai-responses" \
  "$(jq -r '.providers["go-responses"].api' "$dir/models.json")"
check "anthropic-style mapping is absent here" "null" \
  "$(jq -r '.providers.gemini.baseUrl' "$dir/models.json")"

for p in gemini openai 'go-responses'; do
  check "$p apiKey is a \$NAME reference" "1" \
    "$(jq -r --arg p "$p" '.providers[$p].apiKey | test("^\\$[A-Z0-9_]+$") | if . then "1" else "0" end' "$dir/models.json")"
done
leaks="$(grep -rF -e 'dummy-gemini-value' -e 'dummy-openai-value' -e 'dummy-go-value' "$dir" 2>/dev/null || true)"
check "no key value is written under the directory" "" "$leaks"

check "settings defaultProjectTrust is never" "never" "$(jq -r '.defaultProjectTrust' "$dir/settings.json")"
check "settings load no packages" "0" "$(jq -r '.packages | length' "$dir/settings.json")"
check "settings load no extensions" "0" "$(jq -r '.extensions | length' "$dir/settings.json")"
check "settings load no skills" "0" "$(jq -r '.skills | length' "$dir/settings.json")"
check "settings load no prompts" "0" "$(jq -r '.prompts | length' "$dir/settings.json")"

case "$dir" in "$TMP/runner"/*) ok "the directory lives under RUNNER_TEMP";; *) bad "directory outside RUNNER_TEMP: $dir";; esac
case "$dir" in "$TMP/ws"/*) bad "the directory must not live under the workspace";; *) ok "the directory is outside the workspace";; esac
check "directory mode is 700" "700" "$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")"

# Override follows the override, not the built-in.
cat > "$TMP/override.json" <<'JSON'
{"provider": {"openai": {"npm": "@ai-sdk/openai", "options": {"baseURL": "https://override.example/v1", "apiKey": "{env:OPENCODE_OPENAI_API_KEY}"}, "models": {"override-model": {}}}}}
JSON
dir2="$(run_prepare "$TMP/override.json" openai)"
check "the override roster wins" "override-model" "$(jq -r '.providers.openai.models[0].id' "$dir2/models.json")"
check "the override URL wins" "https://override.example/v1" "$(jq -r '.providers.openai.baseUrl' "$dir2/models.json")"

# Unmappable provider: selected fails, unselected is omitted.
cat > "$TMP/unmappable.json" <<'JSON'
{"provider": {"weird": {"npm": "@ai-sdk/unknown", "options": {"apiKey": "{env:WEIRD_KEY}"}, "models": {"m": {}}},
              "openai": {"npm": "@ai-sdk/openai", "options": {"apiKey": "{env:OPENCODE_OPENAI_API_KEY}"}, "models": {"gpt-5.4": {}}}}}
JSON
( export OPENCODE_CONFIG="$TMP/unmappable.json" OPENCODE_REVIEW_REPORT_PROVIDER_ID=weird OPENCODE_OPENAI_API_KEY=x; . "$LIB"; prepare_pi_config "$SETTINGS" >/dev/null 2>&1 ); rc=$?
check "a selected unmappable provider fails" "1" "$rc"
dir3="$(run_prepare "$TMP/unmappable.json" openai)"
check "an unselected unmappable provider is omitted" "openai" "$(jq -r '.providers | keys | join(" ")' "$dir3/models.json")"

cat > "$TMP/credurl.json" <<'JSON'
{"provider":{"openai":{"npm":"@ai-sdk/openai","options":{"baseURL":"https://user:pass@example.test/v1","apiKey":"{env:OPENCODE_OPENAI_API_KEY}"},"models":{"m":{}}}}}
JSON
( export OPENCODE_CONFIG="$TMP/credurl.json" OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_OPENAI_API_KEY=x; . "$LIB"; prepare_pi_config "$SETTINGS" >/dev/null 2>&1 ); rc=$?
check "a credential-bearing base URL is rejected" "1" "$rc"
cat > "$TMP/credurl2.json" <<'JSON'
{"provider":{"openai":{"npm":"@ai-sdk/openai","options":{"baseURL":"https://gw.example.test/v1?api_key=abc","apiKey":"{env:OPENCODE_OPENAI_API_KEY}"},"models":{"m":{}}}}}
JSON
( export OPENCODE_CONFIG="$TMP/credurl2.json" OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_OPENAI_API_KEY=x; . "$LIB"; prepare_pi_config "$SETTINGS" >/dev/null 2>&1 ); rc=$?
check "a query-string credential in the base URL is rejected" "1" "$rc"

( export OPENCODE_CONFIG="$TMP/builtin.json" OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_OPENAI_API_KEY=x RUNNER_TEMP="$TMP/ws" GITHUB_WORKSPACE="$TMP/ws"; . "$LIB"; prepare_pi_config "$SETTINGS" >/dev/null 2>&1 ); rc=$?
check "an agent directory inside the checkout is rejected" "1" "$rc"

# Key helper mapping and failure.
(
  . "$LIB"
  for pair in gemini=OPENCODE_GEMINI_API_KEY openai=OPENCODE_OPENAI_API_KEY go-openai=OPENCODE_GO_OPENAI_API_KEY go-anthropic=OPENCODE_GO_ANTHROPIC_API_KEY openrouter=OPENCODE_OPENROUTER_API_KEY; do
    printf '%s:%s\n' "${pair%%=*}" "$(pi_key_var_for_provider "${pair%%=*}")"
  done
  pi_key_var_for_provider nope >/dev/null 2>&1; echo "unknown:$?"
) > "$TMP/keys.out"
for pair in gemini=OPENCODE_GEMINI_API_KEY openai=OPENCODE_OPENAI_API_KEY go-openai=OPENCODE_GO_OPENAI_API_KEY go-anthropic=OPENCODE_GO_ANTHROPIC_API_KEY openrouter=OPENCODE_OPENROUTER_API_KEY; do
  check "key var for ${pair%%=*}" "${pair%%=*}:${pair#*=}" "$(grep -F "${pair%%=*}:" "$TMP/keys.out" | head -1)"
done
check "an unknown provider id fails" "unknown:1" "$(grep '^unknown:' "$TMP/keys.out")"

# Sourcing must not clobber caller variables.
( SCRIPT_DIR_BEFORE="$SCRIPT_DIR"; REPO_ROOT_BEFORE="$REPO_ROOT"; SCRIPT_DIR=custom; REPO_ROOT=custom2; . "$LIB"; [ "$SCRIPT_DIR" = custom ] && [ "$REPO_ROOT" = custom2 ] ) \
  && ok "sourcing leaves caller variables unchanged" || bad "sourcing clobbered caller variables"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All prepare-pi-config tests passed"; else echo "$fail prepare-pi-config test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
