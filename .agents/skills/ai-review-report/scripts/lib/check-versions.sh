#!/bin/bash
# check-versions.sh — check the opencode CLI and code-review-graph for newer
# releases, and render an update notice for the review report.
#
# Called from run-review.sh after Step 13.5 (code graph analysis), so both
# tools have already been installed and their versions are known regardless
# of whether graph analysis is enabled. Sourced (not exec'd), so the rendered
# strings land in the caller's shell.
#
# Sets (consumed by run-review.sh, passed positionally to aggregate-reviews.sh):
#   OPENCODE_VERSION_INFO    — multi-line Markdown block for the review header
#   OPENCODE_VERSION_FOOTER  — single-line Markdown for the review footer
#
# Also sets, for callers that want the raw values:
#   OPENCODE_CLI_CURRENT_VERSION   — installed opencode CLI version
#   OPENCODE_CLI_LATEST_VERSION    — latest on npm (empty if unknown)
#   GRAPH_CURRENT_VERSION          — installed code-review-graph version (empty
#                                    if the tool isn't installed / graph
#                                    analysis is disabled)
#   GRAPH_LATEST_VERSION           — latest on PyPI (empty if unknown)
#
# All lookups are best-effort: every network call is bounded by --max-time and
# a failure leaves the corresponding variable empty, which renders the report
# exactly as it did before this check existed. A version check must never
# block a review.

# The opencode CLI publishes to npm as `opencode-ai`, NOT `opencode` — the
# latter 404s on the registry. Overridable for tests.
OPENCODE_CLI_NPM_PACKAGE="${OPENCODE_CLI_NPM_PACKAGE:-opencode-ai}"

# Registry bases, overridable so tests can point at local fixture servers.
OPENCODE_NPM_REGISTRY="${OPENCODE_NPM_REGISTRY:-https://registry.npmjs.org}"
GRAPH_PYPI_REGISTRY="${GRAPH_PYPI_REGISTRY:-https://pypi.org/pypi}"
GRAPH_PYPI_PACKAGE="${GRAPH_PYPI_PACKAGE:-code-review-graph}"

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

# _cv_pypi_latest <package> — echo the latest published version, or nothing.
# Scoped names (@scope/name) are percent-encoded as the registry requires,
# mirroring _cv_npm_latest so a future scoped-package fork still resolves.
_cv_pypi_latest() {
  [ "$_cv_have_jq" = "true" ] || return 0
  local _pkg="${1//\//%2F}" _json
  _json=$(curl -sf --max-time 5 "${GRAPH_PYPI_REGISTRY}/${_pkg}/json" 2>/dev/null) || return 0
  printf '%s' "$_json" | jq -r '.info.version // empty' 2>/dev/null || true
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

# --- code-review-graph: installed vs. latest ----------------------------------
# Same parse as build-code-graph.sh. Empty when graph analysis is disabled or
# the install failed — degrades gracefully, no line is rendered below.
GRAPH_CURRENT_VERSION=""
if command -v code-review-graph >/dev/null 2>&1; then
  GRAPH_CURRENT_VERSION="$(code-review-graph --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)*' | head -1 || true)"
fi

GRAPH_LATEST_VERSION=""
if [ -n "$GRAPH_CURRENT_VERSION" ]; then
  GRAPH_LATEST_VERSION="$(_cv_pypi_latest "$GRAPH_PYPI_PACKAGE")"
fi

# --- render -------------------------------------------------------------------
# GitHub-flavoured Markdown; the report is a PR review body, so status is
# carried by emoji (✅ current / ⬆️ update available) rather than ANSI colour.
# The update line names the Variable to bump and links the release notes, so
# the notice is actionable rather than merely informational.

OPENCODE_VERSION_INFO=""
OPENCODE_VERSION_FOOTER=""

if [ -n "$OPENCODE_CLI_CURRENT_VERSION" ] || [ -n "$GRAPH_CURRENT_VERSION" ]; then
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

  # code-review-graph line — only when the tool is actually installed (graph
  # analysis enabled and build succeeded). Same current-vs-latest diff style
  # as the CLI line above, since (unlike the provider SDK) this is a real
  # installed binary with a version we can read.
  if [ -n "$GRAPH_CURRENT_VERSION" ]; then
    if _cv_is_newer "$GRAPH_LATEST_VERSION" "$GRAPH_CURRENT_VERSION"; then
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **code-review-graph:** \`v${GRAPH_CURRENT_VERSION}\` → **\`v${GRAPH_LATEST_VERSION}\`** available ⬆️ — bump \`OPENCODE_REVIEW_REPORT_GRAPH_VERSION\` ([releases](https://github.com/tirth8205/code-review-graph/releases))"
      # If the CLI footer hasn't been written (CLI is current or absent), let
      # the graph notice own the footer — otherwise the footer silently
      # reports "up to date" while the header shows a graph update.
      if [ -z "$OPENCODE_VERSION_FOOTER" ] || [ "$OPENCODE_VERSION_FOOTER" = "*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION}*" ]; then
        OPENCODE_VERSION_FOOTER="*code-review-graph: v${GRAPH_CURRENT_VERSION} → v${GRAPH_LATEST_VERSION} available ⬆️*"
      fi
    else
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **code-review-graph:** \`v${GRAPH_CURRENT_VERSION}\` ✅"
    fi
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
unset _cv_have_jq
unset -f _cv_npm_latest _cv_pypi_latest _cv_is_newer
