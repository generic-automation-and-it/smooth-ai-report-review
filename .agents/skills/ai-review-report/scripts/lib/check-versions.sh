#!/bin/bash
# check-versions.sh — check the opencode CLI and the active provider package
# for newer releases, and render an update notice for the review report.
#
# Called from run-review.sh after the provider is resolved (sourced, not
# exec'd, so the rendered strings land in the caller's shell).
#
# Sets (consumed by run-review.sh, passed positionally to aggregate-reviews.sh):
#   OPENCODE_VERSION_INFO    — multi-line Markdown block for the review header
#   OPENCODE_VERSION_FOOTER  — single-line Markdown for the review footer
#
# Also sets, for callers that want the raw values:
#   OPENCODE_CLI_CURRENT_VERSION     — installed opencode CLI version
#   OPENCODE_CLI_LATEST_VERSION      — latest on npm (empty if unknown)
#   OPENCODE_PROVIDER_NPM_PACKAGE    — npm package backing the active provider
#   OPENCODE_PROVIDER_LATEST_VERSION — latest on npm (empty if unknown)
#
# All lookups are best-effort: every network call is bounded by --max-time and
# a failure leaves the corresponding variable empty, which renders the report
# exactly as it did before this check existed. A version check must never
# block a review.

# The opencode CLI publishes to npm as `opencode-ai`, NOT `opencode` — the
# latter 404s on the registry. Overridable for tests.
OPENCODE_CLI_NPM_PACKAGE="${OPENCODE_CLI_NPM_PACKAGE:-opencode-ai}"

# Registry base, overridable so tests can point at a local fixture server.
OPENCODE_NPM_REGISTRY="${OPENCODE_NPM_REGISTRY:-https://registry.npmjs.org}"

_cv_have_jq="false"
command -v jq >/dev/null 2>&1 && _cv_have_jq="true"

# _cv_npm_latest <package> — echo the latest published version, or nothing.
# Scoped names (@scope/name) are percent-encoded as the registry requires.
_cv_npm_latest() {
  [ "$_cv_have_jq" = "true" ] || return 0
  local _pkg="${1//\//%2F}" _json
  _json=$(curl -sf --max-time 5 "${OPENCODE_NPM_REGISTRY}/${_pkg}/latest" 2>/dev/null) || return 0
  printf '%s' "$_json" | jq -r '.version // empty' 2>/dev/null || true
}

# _cv_is_newer <candidate> <current> — true when candidate sorts strictly
# above current. Uses `sort -V` rather than a bare `!=` so that a pin ahead of
# the registry (or a prerelease suffix) never renders a bogus "update
# available".
_cv_is_newer() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# --- opencode CLI: installed vs. latest ---------------------------------------
# Same parse as install-opencode.sh, so the reported version is exactly the one
# that ran the review.
OPENCODE_CLI_CURRENT_VERSION="$(opencode --version 2>/dev/null \
  | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)?' \
  | head -1 | sed 's/^v//' || true)"
OPENCODE_CLI_LATEST_VERSION="$(_cv_npm_latest "$OPENCODE_CLI_NPM_PACKAGE")"

# --- provider package: latest -------------------------------------------------
# The provider → npm mapping is already declared in opencode.json (each
# provider's `npm` field), installed to ~/.config/opencode/opencode.json by
# setup-opencode-config.sh (which hard-fails if the source is missing, so the
# file is guaranteed present here). Read it rather than duplicating the map —
# a second copy would drift the moment a provider is added.
#
# The provider-id default mirrors run-review.sh's `${…:-gemini}` guards, so a
# caller that invokes run-review.sh without the workflow's job-scoped
# OPENCODE_REVIEW_REPORT_PROVIDER_ID still reports the provider the review
# actually routed to.
OPENCODE_PROVIDER_NPM_PACKAGE=""
_cv_provider_id="${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-gemini}"
_cv_config="$HOME/.config/opencode/opencode.json"
if [ "$_cv_have_jq" = "true" ] && [ -f "$_cv_config" ]; then
  OPENCODE_PROVIDER_NPM_PACKAGE=$(jq -r \
    --arg id "$_cv_provider_id" \
    '.provider[$id].npm // empty' \
    "$_cv_config" 2>/dev/null || true)
fi

OPENCODE_PROVIDER_LATEST_VERSION=""
if [ -n "$OPENCODE_PROVIDER_NPM_PACKAGE" ]; then
  OPENCODE_PROVIDER_LATEST_VERSION="$(_cv_npm_latest "$OPENCODE_PROVIDER_NPM_PACKAGE")"
fi

# --- render -------------------------------------------------------------------
# GitHub-flavoured Markdown; the report is a PR review body, so status is
# carried by emoji (✅ current / ⬆️ update available) rather than ANSI colour.
# The update line names the Variable to bump and links the release notes, so
# the notice is actionable rather than merely informational.

OPENCODE_VERSION_INFO=""
OPENCODE_VERSION_FOOTER=""

if [ -n "$OPENCODE_CLI_CURRENT_VERSION" ]; then
  OPENCODE_VERSION_INFO="📦 **Versions**"

  if _cv_is_newer "$OPENCODE_CLI_LATEST_VERSION" "$OPENCODE_CLI_CURRENT_VERSION"; then
    OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **opencode CLI:** \`v${OPENCODE_CLI_CURRENT_VERSION}\` → **\`v${OPENCODE_CLI_LATEST_VERSION}\`** available ⬆️ — bump \`OPENCODE_REVIEW_REPORT_CLI_VERSION\` ([release notes](https://github.com/sst/opencode/releases))"
    OPENCODE_VERSION_FOOTER="*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION} → v${OPENCODE_CLI_LATEST_VERSION} available ⬆️*"
  else
    OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **opencode CLI:** \`v${OPENCODE_CLI_CURRENT_VERSION}\` ✅"
    OPENCODE_VERSION_FOOTER="*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION}*"
  fi

  # Provider package line. The provider SDK is compiled into the opencode
  # binary — there is no node_modules tree on disk to read an installed
  # version from — so this is a latest-available reference, not a
  # current-vs-latest diff. Labelled as such so it is not misread as "you are
  # behind"; the CLI bump above is what actually moves it.
  if [ -n "$OPENCODE_PROVIDER_NPM_PACKAGE" ] && [ -n "$OPENCODE_PROVIDER_LATEST_VERSION" ]; then
    OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **Provider** (\`${_cv_provider_id}\`) \`${OPENCODE_PROVIDER_NPM_PACKAGE}\`: latest \`v${OPENCODE_PROVIDER_LATEST_VERSION}\` on npm ℹ️ — bundled with the CLI, moves when the CLI is bumped"
  fi
fi

# Log to stdout for workflow-run visibility.
if [ -n "$OPENCODE_VERSION_INFO" ]; then
  echo ""
  echo "$OPENCODE_VERSION_INFO"
  echo ""
fi

# Sourced into the caller's shell — clean up temporaries and helpers so they
# don't leak into run-review.sh (same discipline as lib/resolve-provider.sh).
unset _cv_have_jq _cv_provider_id _cv_config
unset -f _cv_npm_latest _cv_is_newer
