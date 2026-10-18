#!/bin/bash
# Register requested models in the run-local config, never its source (LADR-107).
# Executed, not sourced: cleanup and shell state belong only to this process.
# Usage: bash ensure-opencode-models.sh <resolved-config> <provider-id> [models...]
# Bash 3.2 compatible; registration failures are always advisory.
set -u

warn() { echo "⚠️  ensure-opencode-models: $* — config left unchanged." >&2; }

if [ "$#" -lt 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  warn "resolved config and provider id are required"
  exit 0
fi
config="$1"; provider="$2"; shift 2
[ "$#" -gt 0 ] || exit 0
if [ ! -f "$config" ] || [ ! -r "$config" ] || [ -L "$config" ]; then
  warn "resolved config is not a readable regular file"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  warn "jq is unavailable; unlisted models may remain unavailable"
  exit 0
fi

# Validate before mutation. has(), not //=, preserves explicit null/false keys.
# Native entries take precedence, including malformed ones (never fall through
# to a legacy definition of the same provider). JSONC is deliberately not parsed.
if ! request="$(jq -cs --arg id "$provider" '
    if length != 1 then error("expected one document") else .[0] end
    | if type != "object" then error("expected an object") else . end
    | (if (.providers | type) == "object" and (.providers | has($id)) then "providers"
       elif (.provider | type) == "object" and (.provider | has($id)) then "provider"
       else error("provider absent") end) as $key
    | .[$key][$id] as $p
    | if ($p | type) != "object" then error("provider not object") else . end
    | (if $p | has("models") then $p.models else {} end) as $models
    | if ($models | type) != "object" then error("models not object") else . end
    | {key: $key, missing: ([$ARGS.positional[] | select(length > 0)] | unique
        | map(select(. as $m | $models | has($m) | not)))}
    | select(.missing | length > 0)
  ' --args -- "$@" < "$config" 2>/dev/null)"; then
  warn "unsupported JSON/provider/models shape or unreadable config"
  exit 0
fi
# A true no-op: no reformatting, replacement, permission or timestamp change.
[ -n "$request" ] || exit 0

tmp=""
trap '[ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true' EXIT
# Same-directory temp makes the final rename atomic, including on mounted repos.
if ! tmp="$(mktemp "${config}.models.XXXXXX" 2>/dev/null)"; then
  warn "cannot create temporary config"
  exit 0
fi
if ! jq --arg id "$provider" --argjson request "$request" '
    .[$request.key][$id].models =
      (reduce $request.missing[] as $m ((.[$request.key][$id].models // {}); .[$m] = {}))
  ' < "$config" > "$tmp" 2>/dev/null ||
   ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
  warn "cannot write a valid updated config"
  exit 0
fi
if ! mv -f -- "$tmp" "$config" 2>/dev/null; then
  warn "cannot replace resolved config"
  exit 0
fi
tmp=""
echo "✓ Registered missing requested models for provider '$provider' (resolved copy only)."
exit 0
