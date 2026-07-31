#!/bin/bash
# install-opencode.sh — shared opencode CLI installer for every install path in this repo.
#
# Single source of truth for installing opencode across:
#   - The review gate entrypoint (run-review.sh)
#   - pipeline-ai-analyse.yml (Initialize OPENCODE step)
#   - llm-eval-harness.yml (Install opencode step)
#   - .docs/examples/npm-review-report-gha.yml (consumer template)
#
# Contract (LADR-048): every workflow YAML or consumer-facing example that
# installs opencode delegates to this script — no inline
# `curl -fsSL https://opencode.ai/install | bash`. Duplicating the install
# block silently reintroduces the pin-parity gap this lib closed.
#
# Inputs (env vars, all optional):
#   OPENCODE_REVIEW_REPORT_CLI_VERSION  — version pin (leading `v` stripped);
#                                          blank → `latest`.
#   GITHUB_PATH                          — set by GitHub Actions; appended so
#                                          follow-up steps find opencode.
#
# Behaviour:
#   1. Resolve REQUESTED_VERSION from OPENCODE_REVIEW_REPORT_CLI_VERSION.
#   2. If opencode is already on PATH and matches the request (or request is
#      latest), print the cache-hit line and exit 0.
#   3. Otherwise: run the opencode installer with `--version` CLI flag
#      (via `bash -s -- --version`) when pinned, or bare when latest.
#      Hard-fail on non-zero exit.
#   4. PATH repair: the installer writes to $GITHUB_PATH (SUBSEQUENT steps)
#      and to $HOME/.bashrc (not re-sourced by bash). Export the bin dir
#      explicitly so this shell and follow-up steps in the same job can find
#      opencode.
#   5. Post-install verify: hard-fail if opencode is still missing from PATH,
#      the version can't be parsed, or the installed version mismatches the
#      pin.
#   6. Final echo: `✓ opencode ready (version: X)`.

set -euo pipefail

REQUESTED_VERSION=""
if [ -n "${OPENCODE_REVIEW_REPORT_CLI_VERSION:-}" ]; then
  REQUESTED_VERSION="${OPENCODE_REVIEW_REPORT_CLI_VERSION#v}"
else
  REQUESTED_VERSION="latest"
fi
echo "Requested opencode version: ${REQUESTED_VERSION}"

install_needed="false"
if command -v opencode >/dev/null 2>&1; then
  cached_version="$(opencode --version 2>/dev/null | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)?' | head -1 | sed 's/^v//' || true)"
  if [ -n "$cached_version" ] && { [ "$REQUESTED_VERSION" = "latest" ] || [ "$cached_version" = "$REQUESTED_VERSION" ]; }; then
    echo "✓ opencode found on PATH (version: $cached_version)"
    exit 0
  fi
  install_needed="true"
else
  install_needed="true"
fi

if [ "$install_needed" = "true" ]; then
  echo "Installing opencode (${REQUESTED_VERSION})..."
  if [ "$REQUESTED_VERSION" = "latest" ]; then
    if ! curl -fsSL https://opencode.ai/install | bash; then
      echo "❌ opencode install failed." >&2
      exit 1
    fi
  else
    if ! curl -fsSL https://opencode.ai/install | bash -s -- --version "$REQUESTED_VERSION"; then
      echo "❌ opencode install failed." >&2
      exit 1
    fi
  fi
fi

# The installer writes to $GITHUB_PATH (a GitHub Actions special: it appends
# to PATH of SUBSEQUENT steps, not the current shell). It also appends to
# $HOME/.bashrc, which `bash` does not re-source. The binary lives at
# $HOME/.opencode/bin/opencode — export it explicitly so the verification
# below (and every later `opencode` call in this script or wrapping caller)
# can find it. Also append to $GITHUB_PATH so a follow-up step in the same
# job can find opencode too.
if [ -x "$HOME/.opencode/bin/opencode" ] && ! command -v opencode >/dev/null 2>&1; then
  export PATH="$HOME/.opencode/bin:$PATH"
  echo "$HOME/.opencode/bin" >> "${GITHUB_PATH:-/dev/null}"
fi

if ! command -v opencode >/dev/null 2>&1; then
  echo "❌ opencode is not on PATH after install." >&2
  exit 1
fi
installed_version="$(opencode --version | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)?' | head -1 | sed 's/^v//' || true)"
if [ -z "$installed_version" ]; then
  echo "❌ Unable to determine installed opencode version." >&2
  exit 1
fi
if [ "$REQUESTED_VERSION" != "latest" ] && [ "$installed_version" != "$REQUESTED_VERSION" ]; then
  echo "❌ opencode version mismatch: expected ${REQUESTED_VERSION}, got ${installed_version}." >&2
  exit 1
fi
echo "✓ opencode ready (version: ${installed_version})"
