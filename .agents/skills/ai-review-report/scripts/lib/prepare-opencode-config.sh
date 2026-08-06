#!/bin/bash
# prepare-opencode-config.sh — resolve the opencode.json config, copy it to
# a run-local scratch path, apply LADR-034 baseURL injection, and export
# OPENCODE_CONFIG so opencode picks it up natively.
#
# Must be SOURCED (not exec'd) so the OPENCODE_CONFIG export reaches the
# caller's shell and all child processes (review-in-chunks.sh subshells,
# aggregate-reviews.sh, opencode-with-fallback.sh, etc.).
#
# BECAUSE it is sourced, every variable in here is function-local: the caller's
# own SCRIPT_DIR / REPO_ROOT / SRC must survive this file. Run 31011726946
# broke exactly this way — a file-scope SCRIPT_DIR here clobbered
# run-review.sh's SCRIPT_DIR, so every later "$SCRIPT_DIR/<script>.sh" call
# resolved into scripts/lib/ and died with exit 127 (find-context-files.sh),
# after filter-excluded-files.sh had already failed silently under its
# `|| true`. Do not add file-scope variables to this script.
#
# A caller may override the source via OPENCODE_REVIEW_REPORT_CONFIG (LADR-047) —
# a repo-relative path to a custom opencode.json inside the repo under review.
# Blank keeps the committed default. Used by reusable-workflow consumers that
# ship a customized provider block; the override must still use {env:OPENCODE_*}
# credential placeholders.
#
# Unlike the previous setup-opencode-config.sh, this script never writes to a
# shared non-repo location (~/.config/opencode/opencode.json). It copies the
# config to a run-local scratch path and exports OPENCODE_CONFIG pointing at it.
# This eliminates the personal-config clobber hazard and the is_ours jq guard.
#
# The committed opencode.json ships NO baseURL on the env-driven providers
# (gemini → @ai-sdk/google, github-copilot, openai), so each defaults to its
# native SDK endpoint. When a deployment fronts a provider with a gateway
# (e.g. a LiteLLM proxy), it sets OPENCODE_REVIEW_REPORT_<P>_URL and this
# script injects that value as the provider's options.baseURL in the resolved
# copy (_inject_base_urls, LADR-034). API keys are still read via
# {env:OPENCODE_*_API_KEY}.
# An empty/unset URL var → no baseURL added (native base kept), which is why
# the baseURL is injected dynamically rather than as a static {env:…} placeholder:
# an unset placeholder would substitute to an empty-string baseURL and break the
# SDK. The two OpenCode Go providers, OpenRouter, and the direct Anthropic
# provider are never injected — their base is a fixed public endpoint hardcoded
# in opencode.json (no URL var): https://opencode.ai/zen/go/v1,
# https://openrouter.ai/api/v1, and https://api.anthropic.com respectively.
#
# The resolved config also carries a top-level `instructions` array (LADR-070)
# listing `.agents/rules/*.md`. Relative entries resolve against the project
# directory walking up to the worktree root, NOT against the directory holding
# the config file (only `{file:...}` substitution uses config-relative paths).
# So the glob resolves inside the repo under review, exactly as it would from a
# project-scoped config. No match reads as an empty list, never an error.

# Per-provider baseURL injection (LADR-034). For each env-driven provider whose
# OPENCODE_REVIEW_REPORT_<P>_URL is non-empty, set its options.baseURL in the
# resolved config to that value (e.g. a LiteLLM proxy). Empty/unset → left
# alone (native SDK base). Idempotent: it always sets baseURL to the current env
# value, so a refreshed-from-SRC config (no baseURL) is re-injected each run.
# Only invoked for configs WE manage — we always manage our resolved copy.
# Skipped (with a notice) when jq is unavailable.
_poc_inject_base_urls() {
  local dest="$1" pair id var url tmp
  command -v jq >/dev/null 2>&1 || {
    echo "ℹ️  jq not found — skipping baseURL injection (providers use native SDK base)."
    return 0
  }
  # OpenCode Go, OpenRouter, and Anthropic are intentionally absent — their base
  # is a fixed public endpoint hardcoded in opencode.json, never injected
  # (LADR-027/039/LADR-040).
  for pair in "gemini:OPENCODE_REVIEW_REPORT_GEMINI_URL" \
              "github-copilot:OPENCODE_REVIEW_REPORT_COPILOT_URL" \
              "openai:OPENCODE_REVIEW_REPORT_OPENAI_URL"; do
    id="${pair%%:*}"; var="${pair#*:}"; url="${!var:-}"
    [ -n "$url" ] || continue
    jq -e --arg id "$id" '.provider[$id]' "$dest" >/dev/null 2>&1 || continue
    tmp="$(mktemp)"
    if jq --arg id "$id" --arg url "$url" \
          '.provider[$id].options.baseURL = $url' "$dest" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$dest"
      echo "✓ baseURL injected for provider '$id' (from $var)."
    else
      rm -f "$tmp"
      echo "⚠️  Failed to inject baseURL for '$id' — left config unchanged." >&2
    fi
  done
}

# One-time migration (LADR-071): the previous setup-opencode-config.sh
# INSTALLED the managed config to ~/.config/opencode/opencode.json. That file
# still loads at global scope and merges BELOW OPENCODE_CONFIG — and because
# opencode merges configs per-key, a stale LADR-034-injected provider baseURL
# in it survives whenever the current run injects none (native-endpoint
# deployments) and silently reroutes traffic to a dead gateway. Detect the old
# managed shape (the exact is_ours discriminator the old script used — it never
# matches a personal config, which is what makes the move safe) and move it
# aside. Personal configs are left untouched: they now merge below ours instead
# of blocking the install, and ours wins on every conflicting key.
_poc_migrate_stale_managed_global_config() {
  local dest="$HOME/.config/opencode/opencode.json"
  [ -f "$dest" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "ℹ️  Global opencode.json exists at $dest and jq is unavailable to classify it — leaving it in place. It merges below OPENCODE_CONFIG; ours wins on conflicting keys."
    return 0
  fi
  if jq -e '
      ((keys - ["$schema","provider","permission","agent","share","instructions"]) == [])
      and ((.provider // {} | keys) == ["anthropic","gemini","github-copilot","go-anthropic","go-openai","openai","openrouter"])
      and (all((.provider // {})[]?; ((.options.apiKey // "") | test("^\\{env:OPENCODE_"))))
    ' "$dest" >/dev/null 2>&1; then
    if mv "$dest" "$dest.pre-ladr-071.bak" 2>/dev/null; then
      echo "♻️  Stale managed global config from the pre-OPENCODE_CONFIG flow moved aside: $dest → $dest.pre-ladr-071.bak"
    else
      echo "⚠️  Could not move stale managed global config at $dest — it merges below OPENCODE_CONFIG; a stale injected baseURL there may override a native endpoint." >&2
    fi
  else
    echo "ℹ️  Personal global config detected at $dest — left untouched. It merges BELOW the gate's OPENCODE_CONFIG (ours wins on conflicting keys)."
  fi
}

_poc_main() {
  # Resolve repo root from this script's own location, not `git rev-parse`.
  # local-review.sh sources this script BEFORE it cd's into the repo, so a
  # `git rev-parse --show-toplevel` here crashes when local-review.sh is
  # invoked by absolute path from outside a git working dir. The lib dir is
  # at .agents/skills/ai-review-report/scripts/lib → repo root is 5 levels up.
  local lib_dir repo_root src rel_config resolved preexisting
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$lib_dir/../../../../.." && pwd)"
  src="$repo_root/.agents/skills/ai-review-report/assets/opencode.json"

  # A pre-set OPENCODE_CONFIG (e.g. exported at runner level by a consumer) is
  # REPLACED below, not merged — the gate needs its own resolved config.
  # Captured here so the overwrite is loud; the supported customization channels
  # are OPENCODE_REVIEW_REPORT_CONFIG (LADR-047) and a project opencode.json in
  # the repo under review (which merges ABOVE this file natively).
  preexisting="${OPENCODE_CONFIG:-}"

  _poc_migrate_stale_managed_global_config

  # Optional custom opencode.json (LADR-047). OPENCODE_REVIEW_REPORT_CONFIG lets a
  # caller ship its own provider config instead of the committed one — e.g. a
  # reusable-workflow consumer that customizes the provider block in its own repo.
  # The value is ALWAYS a path relative to the repo under review (GITHUB_WORKSPACE,
  # the workflow's CWD; falls back to the current directory outside CI). Absolute
  # paths are not honoured — the caller's file only exists inside its checkout, so a
  # leading "/" is stripped and the path is still resolved inside the repo. The
  # override MUST NOT contain ".." segments (rejected below) so a malicious or
  # malformed value cannot escape the checkout and read arbitrary host files; it
  # MUST also still keep {env:OPENCODE_*} credential placeholders — never a
  # committed key/URL.
  if [ -n "${OPENCODE_REVIEW_REPORT_CONFIG:-}" ]; then
    rel_config="${OPENCODE_REVIEW_REPORT_CONFIG#/}"   # strip any leading slash → repo-relative
    case "$rel_config" in
      *..*)
        echo "❌ OPENCODE_REVIEW_REPORT_CONFIG='${OPENCODE_REVIEW_REPORT_CONFIG}' contains a '..' segment; the override must stay inside the repo under review." >&2
        return 1
        ;;
    esac
    src="${GITHUB_WORKSPACE:-$PWD}/$rel_config"
    if [ ! -f "$src" ]; then
      echo "❌ Custom opencode.json (OPENCODE_REVIEW_REPORT_CONFIG=${OPENCODE_REVIEW_REPORT_CONFIG}) not found at $src — the path must be relative to the repo under review." >&2
      return 1
    fi
    echo "ℹ️  Using custom opencode.json source: $src (OPENCODE_REVIEW_REPORT_CONFIG override, repo-relative)"
  fi

  if [ ! -f "$src" ]; then
    echo "❌ opencode.json source missing at $src" >&2
    return 1
  fi

  # Resolve the run-local scratch path. In CI (WORK_DIR=ci_temp already created
  # by run-review.sh before Step 5d), use ci_temp/opencode.resolved.json. For
  # local/eval callers that run before ci_temp exists, use mktemp.
  if [ -d "ci_temp" ]; then
    resolved="ci_temp/opencode.resolved.json"
  else
    resolved="$(mktemp /tmp/opencode.resolved.XXXXXX.json)"
  fi

  cp "$src" "$resolved" || return 1
  echo "✓ opencode.json resolved: $src → $resolved"

  _poc_inject_base_urls "$resolved"

  # Export the resolved config path so opencode picks it up natively.
  # Must be ABSOLUTE — opencode may be invoked from other cwd's.
  OPENCODE_CONFIG="$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")"
  export OPENCODE_CONFIG
  echo "✓ OPENCODE_CONFIG=$OPENCODE_CONFIG"

  if [ -n "$preexisting" ] && [ "$preexisting" != "$OPENCODE_CONFIG" ]; then
    echo "⚠️  OPENCODE_CONFIG was already set (${preexisting}) — replaced for this run. Customize the gate's config via OPENCODE_REVIEW_REPORT_CONFIG (LADR-047) or a project opencode.json instead." >&2
  fi

  # Persist across GitHub Actions step boundaries: an `export` dies with this
  # step's shell, and unlike the old install-to-global flow nothing on disk lets
  # a later step find the config. pipeline-ai-analyse.yml sources this lib in
  # "Initialize OPENCODE" but runs opencode in later steps — without this append
  # those steps would run opencode with NO provider config at all.
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "OPENCODE_CONFIG=$OPENCODE_CONFIG" >> "$GITHUB_ENV"
  fi
  return 0
}

# Run, then remove every function this file defined from the sourcing shell.
# The `|| rc=$?` form keeps a failure from tripping the caller's `set -e`
# before cleanup; the final `return`/`exit` re-raises it for the caller.
_poc_rc=0
_poc_main || _poc_rc=$?
unset -f _poc_main _poc_inject_base_urls _poc_migrate_stale_managed_global_config
if [ "$_poc_rc" -ne 0 ]; then
  unset _poc_rc
  return 1 2>/dev/null || exit 1
fi
unset _poc_rc
