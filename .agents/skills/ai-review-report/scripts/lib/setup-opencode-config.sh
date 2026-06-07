#!/bin/bash
# Installs opencode.json from the skill source-of-truth
# (.agents/skills/ai-review-report/assets/opencode.json) into opencode's global
# config location (~/.config/opencode/opencode.json).
#
# Global scope (precedence 2 per opencode docs) is chosen over project scope
# so opencode finds the gemini provider regardless of which directory
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
#   - Local, dest is OUR config (has a gemini block) but references the
#     OLD env-var names: self-heal — refresh it to the committed version so the
#     provider resolves OPENCODE_GEMINI_*. Already-current configs are left as-is.
#   - Local, dest is a hand-rolled personal config (no gemini block):
#     do NOT overwrite. Print actionable guidance so a later "provider/model
#     not found" failure is self-explanatory and the dev can merge it in.
#
# The `gemini` provider is `@ai-sdk/google` using its native Gemini API base
# (no baseURL in opencode.json) and reads OPENCODE_GEMINI_API_KEY via {env:…}.
# A relaying gateway provider (e.g. a LiteLLM proxy with its own baseURL) may be
# added as a separate provider block later.
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
elif grep -q '"gemini"' "$DEST" 2>/dev/null; then
  # The dest has our provider. Only auto-refresh if it is OUR managed shape —
  # solely the providers we ship plus our own optional `permission` and `agent`
  # blocks, no other top-level keys, AND every provider's apiKey is still one of
  # our {env:...} placeholders ({env:OPENCODE_*}, or {env:GH_TOKEN} for the
  # github-copilot provider). That apiKey clause is the real discriminator:
  # it distinguishes our config (which never holds a real key) from a personal
  # config that merely reuses the same provider keys but customizes options to
  # real keys — without it, a key match alone could clobber that personal config.
  # A stale-but-ours config (e.g. old {env:OPENCODE_LITELLM_*} names) still uses
  # the OPENCODE_ placeholder form, so self-heal/refresh is preserved.
  # baseURL is optional: most providers ship with no baseURL (native SDK base) so
  # an absent baseURL passes; the two OpenCode Go providers ship a hardcoded
  # https://opencode.ai/zen/go/v1 base (fixed public Zen endpoint, not env-driven),
  # so a present baseURL must be either our {env:OPENCODE_*} form OR that Zen base.
  # NOTE: jq's `keys` sorts alphabetically, so the committed provider set
  # compares as: gemini, github-copilot, go-anthropic, go-openai, openai.
  is_ours="false"
  jq_available="true"
  if command -v jq >/dev/null 2>&1; then
    jq -e '
      ((keys - ["$schema","provider","permission","agent"]) == [])
      and ((.provider // {} | keys) == ["gemini","github-copilot","go-anthropic","go-openai","openai"])
      and ((.agent // {} | keys) | (. == [] or . == ["review"]))
      and (all((.provider // {})[]?;
            ((.options.apiKey // "") | test("^\\{env:(OPENCODE_|GH_TOKEN)"))
            and ((.options.baseURL // "{env:OPENCODE_}") | test("^(\\{env:OPENCODE_|https://opencode\\.ai/zen/go/)"))))
    ' "$DEST" >/dev/null 2>&1 && is_ours="true"
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
    echo "⚠️  $DEST has a 'gemini' provider but also other settings —"
    echo "    NOT overwriting your personal config. Sync the provider blocks you use"
    echo "    (gemini → {env:OPENCODE_GEMINI_*}, github-copilot →"
    echo "    {env:GH_TOKEN}, openai → {env:OPENCODE_OPENAI_*},"
    echo "    go-openai → {env:OPENCODE_GO_OPENAI_API_KEY}, go-anthropic →"
    echo "    {env:OPENCODE_GO_ANTHROPIC_API_KEY} — both with the hardcoded"
    echo "    https://opencode.ai/zen/go/v1 baseURL) and the"
    echo "    top-level \"permission\": { \"external_directory\": \"allow\" } block from: $SRC"
  fi
else
  echo "⚠️  $DEST exists but has no 'gemini' provider — leaving your personal config untouched."
  echo "    If the review fails with a provider/model-not-found error, merge the"
  echo "    provider block for the provider you use (gemini / github-copilot"
  echo "    / openai / go-openai / go-anthropic) from:"
  echo "      $SRC"
  echo "    into your config at:"
  echo "      $DEST"
fi
