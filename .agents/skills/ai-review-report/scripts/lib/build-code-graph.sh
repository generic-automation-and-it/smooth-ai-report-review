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
#   OPENCODE_REVIEW_REPORT_GRAPH_VERSION    — version pin for code-review-graph;
#                                              blank → latest from PyPI.
#   OPENCODE_REVIEW_REPORT_GRAPH_BASE_REF   — git ref for incremental updates
#                                              (e.g., origin/main). When set,
#                                              runs `build --incremental --base`;
#                                              when blank, runs full `build`.
#   GITHUB_PATH                              — set by GitHub Actions; appended
#                                              so follow-up steps find the CLI.
#
# Behaviour:
#   1. Check if code-review-graph is already installed and matches the version
#      pin (or pin is latest). If so, skip install.
#   2. Install via pip (user-local) if missing or version mismatch.
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
if [ -n "${OPENCODE_REVIEW_REPORT_GRAPH_VERSION:-}" ]; then
  REQUESTED_VERSION="${OPENCODE_REVIEW_REPORT_GRAPH_VERSION#v}"
else
  REQUESTED_VERSION="latest"
fi
echo "Requested code-review-graph version: ${REQUESTED_VERSION}"

# --- Install ----------------------------------------------------------------
# Use a dedicated venv to avoid PEP 668 (externally-managed-environment) on
# modern Ubuntu runners (24.04+), which reject `pip install --user` against
# the system Python unless --break-system-packages is passed. The venv lives
# under ${HOME} so it survives between CI runs when actions/cache warms the
# graph directory.
VENV_DIR="${HOME}/.crg-venv"
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating venv at ${VENV_DIR}..."
  if ! python3 -m venv "$VENV_DIR" 2>&1; then
    echo "❌ python3 venv module unavailable — install python3-venv" >&2
    exit 1
  fi
fi

install_needed="false"
if [ -x "${VENV_DIR}/bin/code-review-graph" ]; then
  cached_version="$("${VENV_DIR}/bin/code-review-graph" --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){0,3}' | head -1 || true)"
  if [ -n "$cached_version" ] && { [ "$REQUESTED_VERSION" = "latest" ] || [ "$cached_version" = "$REQUESTED_VERSION" ]; }; then
    echo "✓ code-review-graph found in venv (version: $cached_version)"
  else
    install_needed="true"
  fi
else
  install_needed="true"
fi

if [ "$install_needed" = "true" ]; then
  echo "Installing code-review-graph (${REQUESTED_VERSION})..."
  if [ "$REQUESTED_VERSION" = "latest" ]; then
    if ! "${VENV_DIR}/bin/pip" install code-review-graph 2>&1 | tail -20; then
      echo "❌ code-review-graph install failed." >&2
      exit 1
    fi
  else
    if ! "${VENV_DIR}/bin/pip" install "code-review-graph==${REQUESTED_VERSION}" 2>&1 | tail -20; then
      echo "❌ code-review-graph install failed." >&2
      exit 1
    fi
  fi
fi

# --- PATH repair --------------------------------------------------------------
# Venv installs land at ${VENV_DIR}/bin. Export for this shell and append to
# GITHUB_PATH so follow-up steps can find the binary.
export PATH="${VENV_DIR}/bin:$PATH"
echo "${VENV_DIR}/bin" >> "${GITHUB_PATH:-/dev/null}"

if ! command -v code-review-graph >/dev/null 2>&1; then
  echo "❌ code-review-graph is not on PATH after install." >&2
  exit 1
fi

installed_version="$(code-review-graph --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){0,3}' | head -1 || true)"
if [ -z "$installed_version" ]; then
  echo "❌ Unable to determine installed code-review-graph version." >&2
  exit 1
fi
if [ "$REQUESTED_VERSION" != "latest" ] && [ "$installed_version" != "$REQUESTED_VERSION" ]; then
  echo "❌ code-review-graph version mismatch: expected ${REQUESTED_VERSION}, got ${installed_version}." >&2
  exit 1
fi
echo "✓ code-review-graph ready (version: ${installed_version})"

# --- Build / update the graph -------------------------------------------------
# CWD-dependent: GRAPH_DIR and `code-review-graph build` both run against the
# current working directory (the repo under review). Keep this in sync with
# the cache step's `path: .code-review-graph` in the workflow YAML.
GRAPH_DIR=".code-review-graph"
BUILD_START="$(date +%s)"

if [ -d "$GRAPH_DIR" ] && [ -f "$GRAPH_DIR/graph.db" ]; then
  echo "Existing graph found — running incremental update..."
  BASE_REF="${OPENCODE_REVIEW_REPORT_GRAPH_BASE_REF:-}"
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
