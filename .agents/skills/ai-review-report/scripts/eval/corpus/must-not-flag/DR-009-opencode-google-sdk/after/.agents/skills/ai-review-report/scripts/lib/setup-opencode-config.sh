#!/bin/bash
# setup-opencode-config.sh — install the managed opencode.json and inject each
# env-driven provider's gateway baseURL at install time (LADR-034).
#
# The committed assets/opencode.json ships NO baseURL on the env-driven
# providers, so an unset URL variable leaves the provider on its native SDK
# endpoint. When a deployment fronts a provider with a gateway (a LiteLLM proxy
# or any OpenAI-compatible surface), the URL variable is set and the value is
# injected here, into the INSTALLED config only.
#
# This is why the `gemini` provider declares npm "@ai-sdk/google" while talking
# to an OpenAI-compatible gateway: opencode is provider-agnostic transport, and
# the SDK label does not dictate the host it connects to.
set -euo pipefail

SRC="${1:?source opencode.json required}"
DEST="${2:?destination opencode.json required}"

install -m 600 -D "$SRC" "$DEST"

# Per-provider baseURL injection. Empty/unset URL → provider left alone.
# The OpenCode Go providers, OpenRouter and the direct Anthropic provider are
# intentionally absent: their base is a fixed public endpoint hardcoded in
# opencode.json and is never injected.
inject_base_urls() {
  local dest="$1" pair id var url tmp
  command -v jq >/dev/null 2>&1 || {
    echo "jq not found — skipping baseURL injection (providers use native SDK base)."
    return 0
  }
  for pair in "gemini:OPENCODE_REVIEW_REPORT_GEMINI_URL" \
              "github-copilot:OPENCODE_REVIEW_REPORT_COPILOT_URL" \
              "openai:OPENCODE_REVIEW_REPORT_OPENAI_URL"; do
    id="${pair%%:*}"
    var="${pair#*:}"
    url="${!var:-}"
    [ -n "$url" ] || continue
    jq -e --arg id "$id" '.provider[$id]' "$dest" >/dev/null 2>&1 || continue
    tmp="$(mktemp)"
    if jq --arg id "$id" --arg url "$url" \
          '.provider[$id].options.baseURL = $url' "$dest" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$dest"
      echo "baseURL injected for provider '${id}' (from ${var})."
    else
      rm -f "$tmp"
      echo "Failed to inject baseURL for '${id}' — left config unchanged." >&2
    fi
  done
}

inject_base_urls "$DEST"
