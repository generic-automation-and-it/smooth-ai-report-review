#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/lib/opencode-with-fallback.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "${tmp_dir}/opencode" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      printf '%s\n' "$2" >> "${OPENCODE_STUB_MODELS_LOG}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'ok\n'
STUB
chmod +x "${tmp_dir}/opencode"

prompt="${tmp_dir}/prompt.md"
printf 'prompt\n' > "$prompt"

run_case() {
  local name="$1" provider="$2" expected="$3" model="$4"
  : > "${tmp_dir}/${name}.models"
  PATH="${tmp_dir}:$PATH" \
    OPENCODE_STUB_MODELS_LOG="${tmp_dir}/${name}.models" \
    OPENCODE_REVIEW_REPORT_PROVIDER_ID="$provider" \
    OPENCODE_MIN_OUTPUT_BYTES=1 \
    bash "$HELPER" "$model" "" "" -- "$prompt" >/dev/null
  actual="$(cat "${tmp_dir}/${name}.models")"
  [ "$actual" = "$expected" ] || {
    echo "FAIL: $name expected '$expected' but got '$actual'" >&2
    exit 1
  }
}

run_case bare_model openai 'openai/gpt-5.5' 'gpt-5.5'
run_case qualified_model go-anthropic 'go-openai/kimi-k2.7-code' 'go-openai/kimi-k2.7-code'
run_case openrouter_bare openrouter 'openrouter/deepseek/deepseek-v4-pro' 'deepseek/deepseek-v4-pro'

echo "✓ opencode-with-fallback target tests passed"
