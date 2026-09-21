#!/bin/bash
# install-rtk.sh — shared rtk-ai/rtk installer + OpenCode plugin init.
#
# Single source of truth for installing RTK (Rust Token Killer) across every
# install path that wants it, mirroring the LADR-048 (install-opencode.sh) and
# LADR-049 (build-code-graph.sh) shared-lib pattern.
#
# Background (LADR-014 → LADR-054): RTK was originally installed as a
# `@google/gemini-cli` tool-call hook and was marked superseded once the
# pipeline moved to `opencode` as its transport (LADR-023) — RTK's Gemini
# hook had no equivalent interception point on opencode. RTK now ships a
# first-class OpenCode plugin (`rtk init --opencode`), closing that gap, so
# this lib re-adopted RTK wired to the opencode v1 plugin surface. OpenCode v2
# has a new plugin API; until RTK releases its proposed `--opencode-v2`
# integration, this lib keeps the binary installed but bypasses only plugin
# initialization. The feature probe makes a future compatible release activate
# automatically without another gate change (LADR-087). See LADR-054 for the
# original decision record.
#
# Inputs (env vars, all optional):
#   OPENCODE_TOOL_RTK_VERSION  — version pin (leading `v` stripped);
#                                          blank → latest.
#   GITHUB_PATH                          — set by GitHub Actions; appended so
#                                          follow-up steps find rtk.
#
# Behaviour:
#   1. Resolve REQUESTED_VERSION from OPENCODE_TOOL_RTK_VERSION.
#   2. If rtk is already on PATH and matches the request (or request is
#      latest), print the cache-hit line and skip straight to init.
#   3. Otherwise: install via the upstream install.sh, which supports pinning
#      through the RTK_VERSION env var (there is no --version CLI flag, unlike
#      opencode's installer).
#   4. PATH repair: the installer writes to ~/.local/bin. Export it explicitly
#      so this shell and follow-up steps in the same job can find rtk.
#   5. Post-install verify: warn (not hard-fail) on a version mismatch or a
#      missing binary — RTK is a token-optimization enhancement, not a hard
#      review dependency, so a bad install must degrade, not abort the gate.
#   6. Select the OpenCode integration from `rtk init --help`: v1 uses
#      `--opencode`; v2 uses `--opencode-v2` once RTK exposes it. Until then,
#      bypass plugin initialization non-fatally while retaining the binary.
#   7. Init the selected OpenCode plugin hook non-interactively.
#   8. Final echo: `✓ rtk ready (version: X)` on active integration, or an
#      explicit installed-but-bypassed line on OpenCode v2.
#
# Exit codes:
#   0 — success (rtk installed; OpenCode plugin initialized when compatible)
#   1 — install or init failure (caller should degrade gracefully, i.e. treat
#       non-zero as "RTK unavailable" and continue the review without it)

set -uo pipefail

REQUESTED_VERSION=""
if [ -n "${OPENCODE_TOOL_RTK_VERSION:-}" ]; then
  REQUESTED_VERSION="${OPENCODE_TOOL_RTK_VERSION#v}"
else
  REQUESTED_VERSION="latest"
fi
echo "Requested rtk version: ${REQUESTED_VERSION}"

install_needed="false"
if command -v rtk >/dev/null 2>&1; then
  cached_version="$(rtk --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -1 || true)"
  if [ -n "$cached_version" ] && { [ "$REQUESTED_VERSION" = "latest" ] || [ "$cached_version" = "$REQUESTED_VERSION" ]; }; then
    echo "✓ rtk found on PATH (version: $cached_version)"
  else
    install_needed="true"
  fi
else
  install_needed="true"
fi

if [ "$install_needed" = "true" ]; then
  echo "Installing rtk (${REQUESTED_VERSION})..."
  if [ "$REQUESTED_VERSION" = "latest" ]; then
    if ! curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh; then
      echo "⚠️  rtk install failed — continuing without it" >&2
      exit 1
    fi
  else
    # rtk's GitHub release tags carry a leading `v` (e.g. `v0.44.1`), and its
    # install.sh uses RTK_VERSION verbatim to build the release download URL
    # — passing the stripped, bare-digit REQUESTED_VERSION 404s. Re-add the
    # `v` only for this call; REQUESTED_VERSION itself must stay bare so the
    # cache-hit/verify comparisons above and below match `rtk --version`'s
    # numeric-only output.
    if ! curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | RTK_VERSION="v${REQUESTED_VERSION}" sh; then
      echo "⚠️  rtk install failed — continuing without it" >&2
      exit 1
    fi
  fi
fi

# install.sh installs to ~/.local/bin. Export it explicitly for this shell
# (same PATH-repair shape as install-opencode.sh / build-code-graph.sh) and
# append to $GITHUB_PATH for follow-up steps in the same job.
if [ -d "$HOME/.local/bin" ] && ! command -v rtk >/dev/null 2>&1; then
  export PATH="$HOME/.local/bin:$PATH"
  echo "$HOME/.local/bin" >> "${GITHUB_PATH:-/dev/null}"
fi

if ! command -v rtk >/dev/null 2>&1; then
  echo "⚠️  rtk is not on PATH after install — continuing without it" >&2
  exit 1
fi
installed_version="$(rtk --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -1 || true)"
if [ -z "$installed_version" ]; then
  echo "⚠️  Unable to determine installed rtk version — continuing without it" >&2
  exit 1
fi
if [ "$REQUESTED_VERSION" != "latest" ] && [ "$installed_version" != "$REQUESTED_VERSION" ]; then
  echo "⚠️  rtk version mismatch: expected ${REQUESTED_VERSION}, got ${installed_version} — continuing anyway" >&2
fi

# Select the compatible OpenCode plugin surface. RTK's released `--opencode`
# integration writes a V1 plugin importing @opencode-ai/plugin, which OpenCode
# v2 cannot execute. Keep the binary installed so its version remains visible,
# but do not write that incompatible plugin. Once a future RTK release exposes
# `--opencode-v2`, the same feature probe activates it automatically.
rtk_opencode_flag="--opencode"
if command -v opencode >/dev/null 2>&1; then
  opencode_version="$(opencode --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -1 || true)"
  opencode_major="${opencode_version%%.*}"
  case "$opencode_major" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$opencode_major" -ge 2 ]; then
        if rtk init --help 2>&1 | grep -Eq -- '--opencode-v2([^[:alnum:]_-]|$)'; then
          rtk_opencode_flag="--opencode-v2"
        else
          echo "⚠️  rtk installed (version: ${installed_version}), but OpenCode integration was bypassed: this RTK release does not expose 'rtk init --opencode-v2'; continuing without RTK optimization." >&2
          exit 0
        fi
      fi
      ;;
  esac
fi

# Wire the OpenCode plugin: -g (global, matches the ephemeral-runner scope of
# every other install in this pipeline), the selected OpenCode integration
# flag, --auto-patch (non-interactive, required for CI), and --hook-only (skip
# writing the human-facing RTK.md instructions file; no one reads it on a
# runner that's destroyed at job end).
if ! rtk init -g "$rtk_opencode_flag" --auto-patch --hook-only; then
  echo "⚠️  rtk init ${rtk_opencode_flag} failed — continuing without RTK enrichment" >&2
  exit 1
fi

echo "✓ rtk ready (version: ${installed_version})"
