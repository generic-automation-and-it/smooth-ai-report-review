#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/lib/resolve-provider.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_success() {
  local name="$1"
  shift
  local env_file="${tmp_dir}/${name}.env"
  GITHUB_ENV="$env_file" "$@" bash "$RESOLVER" >"${tmp_dir}/${name}.out" 2>"${tmp_dir}/${name}.err" || {
    cat "${tmp_dir}/${name}.err" >&2
    fail "$name should have succeeded"
  }
}

run_failure() {
  local name="$1"
  shift
  local env_file="${tmp_dir}/${name}.env"
  if GITHUB_ENV="$env_file" "$@" bash "$RESOLVER" >"${tmp_dir}/${name}.out" 2>"${tmp_dir}/${name}.err"; then
    fail "$name should have failed"
  fi
}

run_success review_go_anthropic env \
  OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-ANTHROPIC \
  OPENCODE_GO_ANTHROPIC_API_KEY=test-key \
  OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=qwen3.7-plus \
  OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=minimax-m2.7 \
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=qwen3.6-pro
grep -q '^OPENCODE_REVIEW_REPORT_PROVIDER_ID=go-anthropic$' "${tmp_dir}/review_go_anthropic.env" || fail "review provider id was not go-anthropic"

run_success analyse_go_openai env \
  OPENCODE_PROVIDER_SCOPE=analyse \
  OPENCODE_ANALYSE_PROVIDER=OPENCODE-GO-OPENAI \
  OPENCODE_ANALYSE_MODEL=kimi-k2.7-code \
  OPENCODE_GO_OPENAI_API_KEY=test-key
grep -q '^OPENCODE_ANALYSE_PROVIDER_ID=go-openai$' "${tmp_dir}/analyse_go_openai.env" || fail "analyse provider id was not go-openai"

run_success analyse_go_anthropic env \
  OPENCODE_PROVIDER_SCOPE=analyse \
  OPENCODE_ANALYSE_PROVIDER=OPENCODE-GO-ANTHROPIC \
  OPENCODE_ANALYSE_MODEL=minimax-m3 \
  OPENCODE_GO_ANTHROPIC_API_KEY=test-key
grep -q '^OPENCODE_ANALYSE_PROVIDER_ID=go-anthropic$' "${tmp_dir}/analyse_go_anthropic.env" || fail "analyse provider id was not go-anthropic"

run_failure analyse_missing_provider env \
  OPENCODE_PROVIDER_SCOPE=analyse \
  OPENCODE_ANALYSE_MODEL=kimi-k2.7-code \
  OPENCODE_GO_OPENAI_API_KEY=test-key
grep -q 'OPENCODE_ANALYSE_MODEL is set but OPENCODE_ANALYSE_PROVIDER is unset' "${tmp_dir}/analyse_missing_provider.err" || fail "missing-provider error was not clear"

run_failure analyse_wrong_go_surface env \
  OPENCODE_PROVIDER_SCOPE=analyse \
  OPENCODE_ANALYSE_PROVIDER=OPENCODE-GO-ANTHROPIC \
  OPENCODE_ANALYSE_MODEL=kimi-k2.7-code \
  OPENCODE_GO_ANTHROPIC_API_KEY=test-key
grep -q 'OpenCode Go OpenAI-compatible surface' "${tmp_dir}/analyse_wrong_go_surface.err" || fail "wrong-surface error was not clear"

echo "✓ resolve-provider scope tests passed"
