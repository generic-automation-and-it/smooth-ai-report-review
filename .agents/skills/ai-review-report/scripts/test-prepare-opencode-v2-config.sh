#!/bin/bash
# Offline regression test for native-v2 custom config baseURL injection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/prepare-opencode-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/ci_temp" "$TMP/home" "$TMP/bin"
cat > "$TMP/repo/opencode.v2.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "openai": {
      "package": "aisdk:@ai-sdk/openai",
      "settings": {"apiKey": "{env:OPENCODE_OPENAI_API_KEY}"}
    }
  }
}
JSON
cat > "$TMP/bin/opencode" <<'STUB'
#!/bin/bash
echo '2.0.11'
STUB
chmod +x "$TMP/bin/opencode"

(
  cd "$TMP/repo"
  # GITHUB_ENV is cleared on purpose: under Actions the lib appends
  # OPENCODE_CONFIG=<temp path> to it, and this temp tree is deleted on exit,
  # so a later step in the same job would inherit a config path that no
  # longer exists (review 5266343056, finding 5).
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" GITHUB_WORKSPACE="$TMP/repo" GITHUB_ENV= \
    OPENCODE_REVIEW_REPORT_CONFIG=opencode.v2.json \
    OPENCODE_REVIEW_REPORT_OPENAI_URL=https://gateway.example/v1 \
    bash -c '. "'$LIB'"; jq -e '\''(.providers.openai.settings.baseURL == "https://gateway.example/v1") and (has("provider") | not)'\'' "$OPENCODE_CONFIG"' \
    > "$TMP/run.out" 2>&1
)

grep -q 'v2 config shape' "$TMP/run.out" || {
  echo "❌ native v2 config injection was not reported" >&2
  cat "$TMP/run.out" >&2
  exit 1
}
echo "✅ native v2 custom config receives settings.baseURL without a legacy provider block"
