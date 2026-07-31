#!/bin/bash
# check-versions.sh — check the opencode CLI, code-review-graph, and rtk for
# newer releases, and render an update notice for the review report.
#
# Called from run-review.sh after Step 13.5 (code graph analysis) and after
# rtk install (step 5c-bis), so all three tools have already been installed
# and their versions are known regardless of whether graph analysis / RTK are
# enabled. Sourced (not exec'd), so the rendered strings land in the caller's
# shell.
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
#   RTK_CURRENT_VERSION            — installed rtk version (empty if the tool
#                                    isn't installed / RTK is disabled)
#   RTK_LATEST_VERSION             — latest GitHub release tag (empty if
#                                    unknown; rtk has no npm/PyPI package)
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

# rtk ships neither an npm nor a PyPI package — it's a GitHub-released Rust
# binary (rtk-ai/rtk), so "latest" comes from the Releases API instead.
RTK_GITHUB_API="${RTK_GITHUB_API:-https://api.github.com}"
RTK_GITHUB_REPO="${RTK_GITHUB_REPO:-rtk-ai/rtk}"

_cv_have_jq="false"
command -v jq >/dev/null 2>&1 && _cv_have_jq="true"

# _cv_npm_latest <package> — echo the latest published version, or nothing.
# Encodes `/` as %2F so npm's @scope/name form survives the URL path; `@`
# itself is allowed in registry paths and is not touched. Current call site
# (opencode-ai) is unscoped, so the substitution is a no-op in practice.
_cv_npm_latest() {
  [ "$_cv_have_jq" = "true" ] || return 0
  local _pkg="${1//\//%2F}" _json
  _json=$(curl -sf --max-time 5 "${OPENCODE_NPM_REGISTRY}/${_pkg}/latest" 2>/dev/null) || return 0
  printf '%s' "$_json" | jq -r '.version // empty' 2>/dev/null || true
}

# _cv_pypi_latest <package> — echo the latest published version, or nothing.
# PyPI uses PEP 503's scope--name form (no `/`) for scoped packages, so this
# substitution is only relevant for non-PEP-503 mirrors. Mirrors
# _cv_npm_latest's encoding for consistency. Current call site
# (code-review-graph) is unscoped.
_cv_pypi_latest() {
  [ "$_cv_have_jq" = "true" ] || return 0
  local _pkg="${1//\//%2F}" _json
  _json=$(curl -sf --max-time 5 "${GRAPH_PYPI_REGISTRY}/${_pkg}/json" 2>/dev/null) || return 0
  printf '%s' "$_json" | jq -r '.info.version // empty' 2>/dev/null || true
}

# _cv_github_latest_tag <owner/repo> — echo the latest release's tag with any
# leading `v` stripped, or nothing. GitHub's REST API requires a User-Agent
# header on every request or it 403s unauthenticated callers.
_cv_github_latest_tag() {
  [ "$_cv_have_jq" = "true" ] || return 0
  local _repo="$1" _json _tag
  _json=$(curl -sf --max-time 5 -H "User-Agent: smooth-ai-report-review" \
    -H "Accept: application/vnd.github+json" \
    "${RTK_GITHUB_API}/repos/${_repo}/releases/latest" 2>/dev/null) || return 0
  _tag=$(printf '%s' "$_json" | jq -r '.tag_name // empty' 2>/dev/null || true)
  printf '%s' "${_tag#v}"
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

# --- rtk: installed vs. latest -------------------------------------------------
# Same parse as install-rtk.sh. Empty when RTK is disabled or the install
# failed — degrades gracefully, no line is rendered below.
RTK_CURRENT_VERSION=""
if command -v rtk >/dev/null 2>&1; then
  RTK_CURRENT_VERSION="$(rtk --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -1 || true)"
fi

RTK_LATEST_VERSION=""
if [ -n "$RTK_CURRENT_VERSION" ]; then
  RTK_LATEST_VERSION="$(_cv_github_latest_tag "$RTK_GITHUB_REPO")"
fi

# --- render -------------------------------------------------------------------
# GitHub-flavoured Markdown; the report is a PR review body, so status is
# carried by emoji (✅ current / ⬆️ update available) rather than ANSI colour.
# The update line names the Variable to bump and links the release notes, so
# the notice is actionable rather than merely informational.

OPENCODE_VERSION_INFO=""
OPENCODE_VERSION_FOOTER=""

if [ -n "$OPENCODE_CLI_CURRENT_VERSION" ] || [ -n "$GRAPH_CURRENT_VERSION" ] || [ -n "$RTK_CURRENT_VERSION" ]; then
  OPENCODE_VERSION_INFO="📦 **Versions**"

  # The outer `if` is widened with `|| GRAPH_CURRENT_VERSION || RTK_CURRENT_VERSION`
  # so a graph-only or RTK-only run still renders a Versions block. That removed the implicit
  # `[ -n "$OPENCODE_CLI_CURRENT_VERSION" ]` guard this inner block used to
  # inherit — re-apply it explicitly so an undetectable CLI version does not
  # produce a stray `v` token in the header/footer.
  if [ -n "$OPENCODE_CLI_CURRENT_VERSION" ]; then
    if _cv_is_newer "$OPENCODE_CLI_LATEST_VERSION" "$OPENCODE_CLI_CURRENT_VERSION"; then
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **opencode CLI:** \`v${OPENCODE_CLI_CURRENT_VERSION}\` → **\`v${OPENCODE_CLI_LATEST_VERSION}\`** available ⬆️ — bump \`OPENCODE_REVIEW_REPORT_CLI_VERSION\` ([release notes](https://github.com/sst/opencode/releases))"
      OPENCODE_VERSION_FOOTER="*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION} → v${OPENCODE_CLI_LATEST_VERSION} available ⬆️*"
    else
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **opencode CLI:** \`v${OPENCODE_CLI_CURRENT_VERSION}\` ✅"
      OPENCODE_VERSION_FOOTER="*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION}*"
    fi
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

  # rtk line — only when the tool is actually installed (RTK enabled and
  # install succeeded). Same current-vs-latest diff style as the CLI/graph
  # lines above. Footer ownership follows the same priority as the graph
  # block: an earlier tool's "behind" notice keeps the footer; rtk only takes
  # it over when nothing has claimed it yet, or the only thing claiming it
  # was CLI's "current" message.
      if [ -n "$RTK_CURRENT_VERSION" ]; then
    if _cv_is_newer "$RTK_LATEST_VERSION" "$RTK_CURRENT_VERSION"; then
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **rtk:** \`v${RTK_CURRENT_VERSION}\` → **\`v${RTK_LATEST_VERSION}\`** available ⬆️ — bump \`OPENCODE_REVIEW_REPORT_RTK_VERSION\` ([releases](https://github.com/${RTK_GITHUB_REPO}/releases))"
      # The literal `*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION}*` below is
      # the priority-chain "current" sentinel: only the CLI's current branch
      # writes a non-arrow footer. rtk takes the footer over only when the
      # CLI is current (or no tool has claimed the footer yet). If graph/rtk
      # ever gain a current-message footer of their own, this comparison
      # would need to broaden to test all three sentinels.
      if [ -z "$OPENCODE_VERSION_FOOTER" ] || [ "$OPENCODE_VERSION_FOOTER" = "*opencode CLI: v${OPENCODE_CLI_CURRENT_VERSION}*" ]; then
        OPENCODE_VERSION_FOOTER="*rtk: v${RTK_CURRENT_VERSION} → v${RTK_LATEST_VERSION} available ⬆️*"
      fi
    else
      OPENCODE_VERSION_INFO="${OPENCODE_VERSION_INFO}
- **rtk:** \`v${RTK_CURRENT_VERSION}\` ✅"
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
unset -f _cv_npm_latest _cv_pypi_latest _cv_github_latest_tag _cv_is_newer
