#!/bin/bash
# install-pi.sh — shared pi CLI installer (LADR-048 pattern, D2/D3).
#
# Single source of truth for installing pi. The official pi.dev installer is
# NOT used: WT-01 measured that it always resolves the latest release and has
# no exact-version argument, so it cannot honour OPENCODE_TOOL_PI_VERSION.
# This lib uses the npm route behind an explicit Node >= 22.19 check.
#
# Inputs (env vars, all optional):
#   OPENCODE_TOOL_PI_VERSION — exact version pin (leading `v` stripped); blank
#                              → reuse an installed pi at or above the floor,
#                              else install the latest release.
#   GITHUB_PATH              — set by GitHub Actions; appended so later steps
#                              find pi.
#
# Behaviour:
#   1. Validate the pin: a version below the measured floor is rejected before
#      anything is installed; a cached pi below the floor is rejected too.
#   2. Require Node >= 22.19 and npm before any install (pi's own engines).
#   3. Exact pin installs exactly that version; blank installs latest only when
#      no acceptable pi is present.
#   4. PATH repair and a post-install version verification.

set -euo pipefail

PI_PACKAGE="@earendil-works/pi-coding-agent"
PI_MIN_VERSION="1.5.2"

REQUESTED_VERSION="latest"
if [ -n "${OPENCODE_TOOL_PI_VERSION:-}" ]; then
  REQUESTED_VERSION="${OPENCODE_TOOL_PI_VERSION#v}"
fi
echo "Requested pi version: ${REQUESTED_VERSION}"

# _pi_ge <a> <b> — true when a >= b (numeric, up to four components).
_pi_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,x,"."); m=split(b,y,".");
    for (i=1;i<=4;i++) { if ((x[i]+0) > (y[i]+0)) exit 0; if ((x[i]+0) < (y[i]+0)) exit 1 }
    exit 0
  }'
}

_pi_version() {
  pi --version 2>/dev/null | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}' | head -1 | sed 's/^v//' || true
}

case "$REQUESTED_VERSION" in
  latest) ;;
  *[!0-9.]*|'') echo "❌ OPENCODE_TOOL_PI_VERSION must be an exact version; got '${REQUESTED_VERSION}'." >&2; exit 1 ;;
  *)
    if ! _pi_ge "$REQUESTED_VERSION" "$PI_MIN_VERSION"; then
      echo "❌ OPENCODE_TOOL_PI_VERSION ${REQUESTED_VERSION} is below the supported pi floor ${PI_MIN_VERSION}." >&2
      exit 1
    fi
    ;;
esac

if ! command -v node >/dev/null 2>&1; then
  echo "❌ pi requires Node.js 22.19.0 or newer; node was not found." >&2
  exit 1
fi
if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=19)?0:1)'; then
  echo "❌ pi requires Node.js 22.19.0 or newer; found $(node --version)." >&2
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "❌ npm is required to install pi." >&2
  exit 1
fi

if command -v pi >/dev/null 2>&1; then
  cached_version="$(_pi_version)"
  if [ -n "$cached_version" ] && _pi_ge "$cached_version" "$PI_MIN_VERSION" \
     && { [ "$REQUESTED_VERSION" = "latest" ] || [ "$cached_version" = "$REQUESTED_VERSION" ]; }; then
    echo "✓ pi found on PATH (version: $cached_version)"
  elif [ -n "$cached_version" ] && ! _pi_ge "$cached_version" "$PI_MIN_VERSION"; then
    echo "❌ Cached pi ${cached_version} is below the supported floor ${PI_MIN_VERSION}; refusing to review on it." >&2
    exit 1
  fi
fi

if [ -z "${cached_version:-}" ] || [ "$REQUESTED_VERSION" != "latest" -a "$cached_version" != "$REQUESTED_VERSION" ]; then
  spec="$PI_PACKAGE"
  [ "$REQUESTED_VERSION" = "latest" ] || spec="${PI_PACKAGE}@${REQUESTED_VERSION}"
  echo "Installing ${spec} …"
  npm install -g --ignore-scripts "$spec" || { echo "❌ npm install failed for ${spec}" >&2; exit 1; }
fi

npm_bin="$(npm prefix -g 2>/dev/null)/bin"
export PATH="${npm_bin}:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$npm_bin" >> "$GITHUB_PATH"
fi

installed_version="$(_pi_version)"
if [ -z "$installed_version" ]; then
  echo "❌ pi is still missing from PATH after install." >&2
  exit 1
fi
if [ "$REQUESTED_VERSION" != "latest" ] && [ "$installed_version" != "$REQUESTED_VERSION" ]; then
  echo "❌ Installed pi ${installed_version} does not match the requested ${REQUESTED_VERSION}." >&2
  exit 1
fi
if ! _pi_ge "$installed_version" "$PI_MIN_VERSION"; then
  echo "❌ Installed pi ${installed_version} is below the supported floor ${PI_MIN_VERSION}." >&2
  exit 1
fi
echo "✓ pi ready (version: ${installed_version})"
