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
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=qwen3.6-plus
grep -q '^OPENCODE_REVIEW_REPORT_PROVIDER_ID=go-anthropic$' "${tmp_dir}/review_go_anthropic.env" || fail "review provider id was not go-anthropic"

run_success review_go_responses env \
  OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-RESPONSES \
  OPENCODE_GO_OPENAI_API_KEY=test-key \
  OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=gpt-5.6-luna \
  OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=grok-4.6 \
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=muse-spark-1.3-contributor
grep -q '^OPENCODE_REVIEW_REPORT_PROVIDER_ID=go-responses$' "${tmp_dir}/review_go_responses.env" || fail "review provider id was not go-responses"

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

# OPENCODE_GO_OPENAI_API_KEY unused: missing-provider check fires before credential check
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

run_failure review_wrong_responses_surface env \
  OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-RESPONSES \
  OPENCODE_GO_OPENAI_API_KEY=test-key \
  OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=glm-5.3 \
  OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=grok-4.6 \
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=grok-4.6
grep -q 'not an OpenCode Go Responses API model' "${tmp_dir}/review_wrong_responses_surface.err" || fail "wrong Responses-surface error was not clear"

# Credential-missing path: provider and URL set, model set, but API key absent.
run_failure analyse_missing_cred env \
  OPENCODE_PROVIDER_SCOPE=analyse \
  OPENCODE_ANALYSE_PROVIDER=GEMINI \
  OPENCODE_ANALYSE_MODEL=gemini-2.5-pro \
  OPENCODE_REVIEW_REPORT_GEMINI_URL=https://example.com
grep -q 'OPENCODE_GEMINI_API_KEY.*empty/unset' "${tmp_dir}/analyse_missing_cred.err" || fail "missing-credential error was not clear"

# --- decisions scope (LADR-093) --------------------------------------------------
# Resolved by sourcing, like the scorer does: the values are shell variables and
# the key must never reach $GITHUB_ENV.
decisions_resolve() { # decisions_resolve <name> <env...> — prints provider|url|model|key-var
  local name="$1"
  shift
  env GITHUB_ENV="${tmp_dir}/${name}.env" "$@" OPENCODE_PROVIDER_SCOPE=decisions bash -c '
    . "$0" >/dev/null || exit 1
    printf "%s|%s|%s|%s|%s" "$OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER" "$OPENCODE_REVIEW_REPORT_DECISIONS_URL" \
      "$OPENCODE_REVIEW_REPORT_DECISIONS_MODEL" "$OPENCODE_DECISIONS_KEY_VAR" "$OPENCODE_DECISIONS_API_KEY"
  ' "$RESOLVER" 2>"${tmp_dir}/${name}.err"
}

out="$(decisions_resolve decisions_default OPENCODE_GO_OPENAI_API_KEY=go-key)" || fail "decisions default should resolve"
[ "$out" = "OPENCODE-GO-DECISIONS|https://opencode.ai/zen/v1/systemone|jev-1.13|OPENCODE_GO_OPENAI_API_KEY|go-key" ] \
  || fail "decisions default resolved to '$out'"
[ ! -s "${tmp_dir}/decisions_default.env" ] || fail "decisions scope wrote to GITHUB_ENV"

out="$(decisions_resolve decisions_or OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=openrouter-decisions OPENCODE_OPENROUTER_API_KEY=or-key)" \
  || fail "OPENROUTER-DECISIONS should resolve"
[ "$out" = "OPENROUTER-DECISIONS|https://openrouter.ai/api/alpha/decisions|typesafe/jev-1.13|OPENCODE_OPENROUTER_API_KEY|or-key" ] \
  || fail "OPENROUTER-DECISIONS resolved to '$out'"

out="$(decisions_resolve decisions_model OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13-free OPENCODE_GO_OPENAI_API_KEY=go-key)" \
  || fail "decisions model override should resolve"
[ "${out%%|OPENCODE_GO*}" = "OPENCODE-GO-DECISIONS|https://opencode.ai/zen/v1/systemone|jev-1.13-free" ] || fail "decisions model override ignored: '$out'"

# The review provider's key is never reused, and never clobbered.
env OPENCODE_GO_OPENAI_API_KEY=go-key OPENCODE_GATEWAY_API_KEY=review-key OPENCODE_PROVIDER_SCOPE=decisions \
  bash -c '. "$0" >/dev/null; printf "%s" "$OPENCODE_GATEWAY_API_KEY"' "$RESOLVER" > "${tmp_dir}/gw.out" 2>/dev/null
[ "$(cat "${tmp_dir}/gw.out")" = "review-key" ] || fail "decisions scope touched OPENCODE_GATEWAY_API_KEY"

if decisions_resolve decisions_missing_key >/dev/null; then fail "decisions scope without a key should fail"; fi
grep -q 'OPENCODE_GO_OPENAI_API_KEY is empty/unset' "${tmp_dir}/decisions_missing_key.err" || fail "decisions missing-key error was not clear"

if decisions_resolve decisions_chat OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENAI OPENCODE_OPENAI_API_KEY=k >/dev/null; then
  fail "a chat provider must be refused by the decisions scope"
fi
grep -q 'is a chat provider' "${tmp_dir}/decisions_chat.err" || fail "decisions chat-provider error was not clear"

if decisions_resolve decisions_crossed OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENROUTER-DECISIONS \
     OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13 OPENCODE_OPENROUTER_API_KEY=k >/dev/null; then
  fail "an OpenCode model id must be refused on OPENROUTER-DECISIONS"
fi
grep -q 'has no vendor prefix' "${tmp_dir}/decisions_crossed.err" || fail "decisions crossed-model error was not clear"

# And the reverse: a decision provider can never become the review provider.
run_failure review_decisions_provider env \
  OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-DECISIONS \
  OPENCODE_GO_OPENAI_API_KEY=test-key \
  OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=jev-1.13 \
  OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=jev-1.13 \
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=jev-1.13
grep -q 'is a decision-model provider' "${tmp_dir}/review_decisions_provider.err" || fail "review-scope decision-provider error was not clear"

echo "✓ resolve-provider scope tests passed"
