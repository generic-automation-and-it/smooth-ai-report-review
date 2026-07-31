#!/bin/bash
# build-code-graph.sh — install code-review-graph and build/update the SQLite knowledge graph.
#
# Single source of truth for building the code knowledge graph across:
#   - The review gate entrypoint (run-review.sh, Step 13.5)
#   - Future: pipeline-ai-analyse.yml, local-review.sh
#
# Contract (LADR-049): every workflow or consumer that builds the code graph
# delegates to this script — no inline `pip install code-review-graph` in
# workflow YAML. This mirrors the LADR-048 pattern for install-opencode.sh.
#
# Inputs (env vars, all optional):
#   OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION    — version pin for code-review-graph;
#                                              blank → latest from PyPI.
#   OPENCODE_TOOL_CODE_REVIEW_GRAPH_BASE_REF   — git ref for incremental updates
#                                              (e.g., origin/main). When set,
#                                              runs `build --incremental --base`;
#                                              when blank, runs full `build`.
#   GITHUB_PATH                              — set by GitHub Actions; appended
#                                              so follow-up steps find the CLI.
#
# Behaviour:
#   1. Check if code-review-graph is already installed and matches the version
#      pin (or pin is latest). If so, skip install.
#   2. Install via pipx (isolated venv) if missing or version mismatch —
#      falls back to `pip install --user` only to bootstrap pipx itself.
#   3. Build or incrementally update the graph in .code-review-graph/.
#   4. Verify the graph DB exists and is non-empty.
#   5. Print summary: node count, edge count, build time.
#
# Exit codes:
#   0 — success (graph built/updated)
#   1 — install or build failure (caller should degrade gracefully)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Version resolution -------------------------------------------------------
REQUESTED_VERSION=""
if [ -n "${OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION:-}" ]; then
  REQUESTED_VERSION="${OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION#v}"
else
  REQUESTED_VERSION="latest"
fi
echo "Requested code-review-graph version: ${REQUESTED_VERSION}"

# --- Semver-aware version equality -------------------------------------------
# _ver_eq <a> <b> — return 0 if versions are semver-equal (treats 2.9 as equal
# to 2.9.0, 2.9.0.0, etc.). Padding is per-segment so 2.9.1 != 2.9.0.
_ver_eq() {
  [ "$1" = "$2" ] && return 0
  local IFS=. a=($1) b=($2) i
  while [ "${#a[@]}" -lt "${#b[@]}" ]; do a+=(0); done
  while [ "${#b[@]}" -lt "${#a[@]}" ]; do b+=(0); done
  for i in "${!a[@]}"; do
    [ "${a[i]}" != "${b[i]}" ] && return 1
  done
  return 0
}

# --- Install check ------------------------------------------------------------
install_needed="false"
if command -v code-review-graph >/dev/null 2>&1; then
  cached_version="$(code-review-graph --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)*' | head -1 || true)"
  if [ -n "$cached_version" ] && { [ "$REQUESTED_VERSION" = "latest" ] || _ver_eq "$cached_version" "$REQUESTED_VERSION"; }; then
    echo "✓ code-review-graph found on PATH (version: $cached_version)"
  else
    install_needed="true"
  fi
else
  install_needed="true"
fi

if [ "$install_needed" = "true" ]; then
  echo "Installing code-review-graph (${REQUESTED_VERSION})..."
  # Use pipx for isolated install — avoids PEP 668 "externally-managed-environment"
  # errors on Ubuntu 24.04+ (ubuntu-latest) where pip install --user is rejected.
  # pipx installs to ~/.local/bin and creates an isolated venv per package.
  if ! command -v pipx >/dev/null 2>&1; then
    echo "  Installing pipx for isolated Python package management..."
    if ! python3 -m pip install --user --break-system-packages pipx 2>/dev/null; then
      # Fallback: try without --break-system-packages (older Python / macOS)
      python3 -m pip install --user pipx || {
        echo "❌ pipx install failed." >&2
        exit 1
      }
    fi
    export PATH="$HOME/.local/bin:$PATH"
    echo "$HOME/.local/bin" >> "${GITHUB_PATH:-/dev/null}"
  fi
  # --force reinstalls even when a different version is already present —
  # without it, pipx exits non-zero on "already installed" and the version-
  # mismatch case above always fails here.
  if [ "$REQUESTED_VERSION" = "latest" ]; then
    if ! pipx install --force code-review-graph; then
      echo "❌ code-review-graph install failed." >&2
      exit 1
    fi
  else
    if ! pipx install --force "code-review-graph==${REQUESTED_VERSION}"; then
      echo "❌ code-review-graph install failed." >&2
      exit 1
    fi
  fi
fi

# --- PATH repair --------------------------------------------------------------
# pip --user installs to ~/.local/bin on most platforms. Ensure it's on PATH
# for this shell and follow-up steps.
if [ -d "$HOME/.local/bin" ] && ! command -v code-review-graph >/dev/null 2>&1; then
  export PATH="$HOME/.local/bin:$PATH"
  echo "$HOME/.local/bin" >> "${GITHUB_PATH:-/dev/null}"
fi

if ! command -v code-review-graph >/dev/null 2>&1; then
  echo "❌ code-review-graph is not on PATH after install." >&2
  exit 1
fi

installed_version="$(code-review-graph --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)*' | head -1 || true)"
if [ -z "$installed_version" ]; then
  echo "❌ Unable to determine installed code-review-graph version." >&2
  exit 1
fi
if [ "$REQUESTED_VERSION" != "latest" ] && ! _ver_eq "$installed_version" "$REQUESTED_VERSION"; then
  echo "❌ code-review-graph version mismatch: expected ${REQUESTED_VERSION}, got ${installed_version}." >&2
  exit 1
fi
echo "✓ code-review-graph ready (version: ${installed_version})"

# --- Build / update the graph -------------------------------------------------
GRAPH_DIR=".code-review-graph"
BUILD_START="$(date +%s)"

if [ -d "$GRAPH_DIR" ] && [ -f "$GRAPH_DIR/graph.db" ]; then
  echo "Existing graph found — running incremental update..."
  BASE_REF="${OPENCODE_TOOL_CODE_REVIEW_GRAPH_BASE_REF:-}"
  if [ -n "$BASE_REF" ]; then
    echo "  Base ref: ${BASE_REF}"
    if ! code-review-graph build --incremental --base "$BASE_REF"; then
      echo "⚠️  Incremental update failed — falling back to full rebuild" >&2
      if ! code-review-graph build; then
        echo "❌ Full graph build failed." >&2
        exit 1
      fi
    fi
  else
    # No base ref — just do a full rebuild (cheaper than guessing the base)
    if ! code-review-graph build; then
      echo "❌ Graph build failed." >&2
      exit 1
    fi
  fi
else
  echo "No existing graph — running full build..."
  if ! code-review-graph build; then
    echo "❌ Graph build failed." >&2
    exit 1
  fi
fi

BUILD_END="$(date +%s)"
BUILD_TIME=$((BUILD_END - BUILD_START))

# --- Verify the graph ---------------------------------------------------------
if [ ! -f "$GRAPH_DIR/graph.db" ]; then
  echo "❌ Graph build completed but $GRAPH_DIR/graph.db not found." >&2
  exit 1
fi

# Try to get stats (the CLI may not have a stats command; fall back to file size)
if code-review-graph stats >/dev/null 2>&1; then
  echo ""
  echo "📊 Graph statistics:"
  code-review-graph stats 2>/dev/null | head -20 || true
else
  DB_SIZE="$(du -h "$GRAPH_DIR/graph.db" 2>/dev/null | cut -f1 || echo "unknown")"
  echo "  Graph DB size: ${DB_SIZE}"
fi

echo ""
echo "✓ Code graph built in ${BUILD_TIME}s at $GRAPH_DIR/"
echo "  code-review-graph version: ${installed_version}"
