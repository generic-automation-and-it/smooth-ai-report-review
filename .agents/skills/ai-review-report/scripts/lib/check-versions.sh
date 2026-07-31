#!/bin/bash
# check-versions.sh — check for CLI and provider package updates.
#
# Called from run-review.sh after opencode is installed (sourced, not exec'd).
# Queries the npm registry for the latest versions and sets env vars for the
# review header/footer to render update notices.
#
# Sets (env vars, consumed by aggregate-reviews.sh via run-review.sh):
#   OPENCODE_CLI_CURRENT_VERSION     — installed opencode CLI version
#   OPENCODE_CLI_LATEST_VERSION      — latest version on npm (empty if unknown)
#   OPENCODE_PROVIDER_NPM_PACKAGE    — npm package name for the active provider
#   OPENCODE_PROVIDER_CURRENT_VERSION — provider SDK version used at runtime
#   OPENCODE_PROVIDER_LATEST_VERSION  — latest version on npm (empty if unknown)
#
# All checks are best-effort — failures are silently skipped so a network
# hiccup never blocks the review.

# --- opencode CLI version (installed) ----------------------------------------
OPENCODE_CLI_CURRENT_VERSION="$(opencode --version 2>/dev/null \
  | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)?' \
  | head -1 | sed 's/^v//' || true)"

# --- opencode CLI latest on npm ----------------------------------------------
OPENCODE_CLI_LATEST_VERSION=""
if _cli_json=$(curl -sf --max-time 5 https://registry.npmjs.org/opencode/latest 2>/dev/null); then
  OPENCODE_CLI_LATEST_VERSION=$(echo "$_cli_json" | jq -r '.version // empty' 2>/dev/null || true)
fi

# --- provider npm package name -----------------------------------------------
# Map provider ID → npm SDK package. Hardcoded mapping matches
# assets/opencode.json; kept in sync manually (the JSON is read by the
# opencode runtime, not by this shell script at review time).
_provider_npm_for_id() {
  case "$1" in
    gemini)         echo "@ai-sdk/google" ;;
    github-copilot) echo "@ai-sdk/github-copilot" ;;
    openai)         echo "@ai-sdk/openai" ;;
    anthropic)      echo "@ai-sdk/anthropic" ;;
    go-openai)      echo "@ai-sdk/openai-compatible" ;;
    go-anthropic)   echo "@ai-sdk/anthropic" ;;
    openrouter)     echo "@openrouter/ai-sdk-provider" ;;
    *)              echo "" ;;
  esac
}

OPENCODE_PROVIDER_NPM_PACKAGE=""
if [ -n "${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-}" ]; then
  # Try extracting from the installed opencode.json first (single source of
  # truth for provider → npm mapping). Fall back to the hardcoded map above.
  _oc_cfg="$HOME/.config/opencode/opencode.json"
  if [ -f "$_oc_cfg" ] && command -v jq >/dev/null 2>&1; then
    OPENCODE_PROVIDER_NPM_PACKAGE=$(jq -r \
      ".provider[\"${OPENCODE_REVIEW_REPORT_PROVIDER_ID}\"].npm // empty" \
      "$_oc_cfg" 2>/dev/null || true)
  fi
  if [ -z "$OPENCODE_PROVIDER_NPM_PACKAGE" ]; then
    OPENCODE_PROVIDER_NPM_PACKAGE=$(_provider_npm_for_id "${OPENCODE_REVIEW_REPORT_PROVIDER_ID}")
  fi
fi

# --- provider SDK latest on npm ----------------------------------------------
OPENCODE_PROVIDER_LATEST_VERSION=""
if [ -n "$OPENCODE_PROVIDER_NPM_PACKAGE" ]; then
  _encoded_pkg=$(echo "$OPENCODE_PROVIDER_NPM_PACKAGE" | sed 's|/|%2F|g')
  if _prov_json=$(curl -sf --max-time 5 "https://registry.npmjs.org/${_encoded_pkg}/latest" 2>/dev/null); then
    OPENCODE_PROVIDER_LATEST_VERSION=$(echo "$_prov_json" | jq -r '.version // empty' 2>/dev/null || true)
  fi
fi

# Provider SDK version used at install time (matches what opencode resolved
# when it set up its node_modules). This is informational — the SDK is
# managed by opencode, not pinned by the user.
OPENCODE_PROVIDER_CURRENT_VERSION=""

# --- build version-info block for the review header --------------------------
# Renders a compact block that aggregate-reviews.sh inserts after the Model
# line. Empty string when nothing could be determined.
#
# Format (GitHub-flavoured Markdown — no ANSI colour; uses emoji for status):
#   📦 **Versions**
#   • OpenCode CLI: v1.2.3 ✅
#   • @ai-sdk/google: v8.2.0 → **v8.3.0** available ⬆️

OPENCODE_VERSION_INFO=""

if [ -n "$OPENCODE_CLI_CURRENT_VERSION" ]; then
  OPENCODE_VERSION_INFO="📦 **Versions**"

  # CLI line
  if [ -n "$OPENCODE_CLI_LATEST_VERSION" ] && \
     [ "$OPENCODE_CLI_LATEST_VERSION" != "$OPENCODE_CLI_CURRENT_VERSION" ]; then
    OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
• **OpenCode CLI:** v${OPENCODE_CLI_CURRENT_VERSION} → **v${OPENCODE_CLI_LATEST_VERSION}** available ⬆️"
  else
    OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
• **OpenCode CLI:** v${OPENCODE_CLI_CURRENT_VERSION} ✅"
  fi

  # Provider line (only when we know the package name and have a latest version).
  # The provider SDK is managed by opencode (not pinned by the user), so we
  # show the npm latest as an informational reference — users can compare
  # against their provider changelog to see if they're current.
  if [ -n "$OPENCODE_PROVIDER_NPM_PACKAGE" ] && [ -n "$OPENCODE_PROVIDER_LATEST_VERSION" ]; then
    if [ -n "$OPENCODE_PROVIDER_CURRENT_VERSION" ] && \
       [ "$OPENCODE_PROVIDER_LATEST_VERSION" != "$OPENCODE_PROVIDER_CURRENT_VERSION" ]; then
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
• **${OPENCODE_PROVIDER_NPM_PACKAGE}:** v${OPENCODE_PROVIDER_CURRENT_VERSION} → **v${OPENCODE_PROVIDER_LATEST_VERSION}** available ⬆️"
    else
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
• **${OPENCODE_PROVIDER_NPM_PACKAGE}:** latest v${OPENCODE_PROVIDER_LATEST_VERSION}"
    fi
  fi
fi

# Log to stdout for workflow-run visibility
if [ -n "$OPENCODE_VERSION_INFO" ]; then
  echo ""
  echo "$OPENCODE_VERSION_INFO"
  echo ""
fi
