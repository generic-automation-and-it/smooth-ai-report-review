#!/bin/bash
# Installs opencode.json from the skill source-of-truth
# (.agents/skills/ai-review-report/assets/opencode.json) into opencode's global
# config location (~/.config/opencode/opencode.json).
#
# Global scope (precedence 2 per opencode docs) is chosen over project scope
# so opencode finds the litellm-gemini provider regardless of which directory
# the review scripts are invoked from. The repo source remains the single
# committed source of truth.
#
# Install policy differs by environment to avoid clobbering a developer's
# personal opencode config (the dest is a shared, non-repo location):
#   - CI: always refresh. On an ephemeral GitHub-hosted runner the dest won't
#     exist yet; on a reused/self-hosted runner a stale config from a prior run
#     must be overwritten so the runner picks up the current provider definition.
#     Either way no human's personal config lives there, so overwriting is safe.
#   - Local, dest missing: install it (first run).
#   - Local, dest is OUR config (has a litellm-gemini block) but references the
#     OLD env-var names: self-heal — refresh it to the committed version so the
#     provider resolves OPENCODE_GEMININ_*. Already-current configs are left as-is.
#   - Local, dest is a hand-rolled personal config (no litellm-gemini block):
#     do NOT overwrite. Print actionable guidance so a later "provider/model
#     not found" failure is self-explanatory and the dev can merge it in.
#
# Provider config consumes the existing OPENCODE_GEMININ_URL / OPENCODE_GEMININ_API_KEY
# env vars directly (see opencode.json). The provider type is @ai-sdk/google
# pointed at LiteLLM's Gemini-native baseURL — confirmed working for relayed
# Gemini setups in upstream issue anomalyco/opencode#5777.
#
# Must run AFTER actions/checkout — see LADR-023.

set -e

# Resolve repo root from this script's own location, not `git rev-parse`.
# local-review.sh sources this script BEFORE it cd's into the repo, so a
# `git rev-parse --show-toplevel` here crashes when local-review.sh is
# invoked by absolute path from outside a git working dir. SCRIPT_DIR is
# at .agents/skills/ai-review-report/scripts/lib → repo root is 5 levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
SRC="$REPO_ROOT/.agents/skills/ai-review-report/assets/opencode.json"
DEST_DIR="$HOME/.config/opencode"
DEST="$DEST_DIR/opencode.json"

if [ ! -f "$SRC" ]; then
  echo "❌ opencode.json source missing at $SRC" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

if [ "${CI:-}" = "true" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
  cp "$SRC" "$DEST"
  echo "✓ opencode.json installed (CI — always refreshed): $SRC → $DEST"
elif [ ! -f "$DEST" ]; then
  cp "$SRC" "$DEST"
  echo "✓ opencode.json installed: $SRC → $DEST"
elif grep -q '"litellm-gemini"' "$DEST" 2>/dev/null; then
  # The dest has our provider. Only auto-refresh if it is OUR managed shape —
  # solely the providers we ship plus our own optional `permission` block, and no
  # other top-level keys. A developer may have hand-merged a provider into a
  # personal config (per the else-branch guidance); NEVER clobber that.
  # NOTE: jq's `keys` sorts alphabetically, so the committed provider set
  # (github-copilot, litellm-gemini, openai) compares in that order.
  is_ours="false"
  jq_available="true"
  if command -v jq >/dev/null 2>&1; then
    jq -e '((keys - ["$schema","provider","permission"]) == []) and ((.provider // {} | keys) == ["github-copilot","litellm-gemini","openai"])' \
      "$DEST" >/dev/null 2>&1 && is_ours="true"
  else
    jq_available="false"
  fi
  if [ "$is_ours" = "true" ]; then
    if cmp -s "$SRC" "$DEST"; then
      echo "✓ opencode.json already current: $DEST"
    else
      # Our-shape but stale (old env-var names, or missing the new permission
      # block, or any other drift). Safe to refresh to the committed version.
      cp "$SRC" "$DEST"
      echo "♻️  Stale opencode.json detected — refreshed to the committed version (provider + permission): $DEST"
    fi
  elif [ "$jq_available" = "false" ]; then
    # jq is required to safely tell our managed config apart from a hand-rolled
    # personal one, so we can't auto-refresh — leave the file untouched (safe).
    echo "ℹ️  jq not found — can't verify $DEST is the managed config, so it's left untouched."
    echo "    Install jq (brew install jq / apt-get install jq) to enable auto-refresh of this config."
  else
    echo "⚠️  $DEST has a 'litellm-gemini' provider but also other settings —"
    echo "    NOT overwriting your personal config. Sync the provider.litellm-gemini"
    echo "    options ({env:OPENCODE_GEMININ_URL}/{env:OPENCODE_GEMININ_API_KEY}) and the"
    echo "    top-level \"permission\": { \"external_directory\": \"allow\" } block from: $SRC"
  fi
else
  echo "⚠️  $DEST exists but has no 'litellm-gemini' provider — leaving your personal config untouched."
  echo "    If the review fails with a provider/model-not-found error, merge the"
  echo "    'provider.litellm-gemini' block from:"
  echo "      $SRC"
  echo "    into your config at:"
  echo "      $DEST"
fi
