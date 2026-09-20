#!/bin/bash
# Offline regression tests for the shared OpenCode v2 installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/lib/install-opencode.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "❌ $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "✅ $*"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_CURL_LOG"
cat <<'INSTALL'
#!/bin/bash
set -e
version="2.0.11"
if [ "${1:-}" = "--version" ]; then version="$2"; fi
mkdir -p "$HOME/.opencode/bin"
cat > "$HOME/.opencode/bin/opencode" <<EOF
#!/bin/bash
echo "$version"
EOF
chmod +x "$HOME/.opencode/bin/opencode"
INSTALL
STUB
chmod +x "$TMP/bin/curl"

run_case() {
  local name="$1" version="$2" home
  home="$TMP/$name/home"
  mkdir -p "$home"
  : > "$TMP/$name.github_path"
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$home" \
    GITHUB_PATH="$TMP/$name.github_path" STUB_CURL_LOG="$TMP/$name.curl" \
    OPENCODE_CLI_VERSION="$version" bash "$INSTALLER" > "$TMP/$name.out"
}

run_case latest ""
grep -q 'https://opencode.ai/v2/install' "$TMP/latest.curl" \
  || fail "latest install did not use the v2 installer URL"
grep -q 'opencode ready (version: 2.0.11)' "$TMP/latest.out" \
  || fail "latest install did not verify the installed v2 version"
ok "latest uses the v2 installer and verifies the binary"

run_case pinned "v2.0.9"
grep -q 'https://opencode.ai/v2/install' "$TMP/pinned.curl" \
  || fail "pinned install did not use the v2 installer URL"
grep -q 'opencode ready (version: 2.0.9)' "$TMP/pinned.out" \
  || fail "pinned install did not forward/verify the requested v2 version"
ok "a leading-v 2.x pin is normalized, forwarded, and verified"

if env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/rejected/home" \
  GITHUB_PATH="$TMP/rejected.github_path" STUB_CURL_LOG="$TMP/rejected.curl" \
  OPENCODE_CLI_VERSION="1.18.10" bash "$INSTALLER" > "$TMP/rejected.out" 2>&1; then
  fail "a 1.x pin unexpectedly passed the v2-only installer"
fi
grep -q 'must pin an OpenCode v2 release' "$TMP/rejected.out" \
  || fail "rejected 1.x pin did not explain the required GitHub Variable migration"
ok "a stale 1.x GitHub Variable fails fast with migration guidance"

echo "All $pass install-opencode tests passed"
