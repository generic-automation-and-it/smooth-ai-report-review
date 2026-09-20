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

# --- v1/v2 share the binary name (https://opencode.ai/v2/docs/migrate-v1/) ---
# "OpenCode 1 and OpenCode 2 both use the opencode command and are no longer
# installed side by side by default." Two failure modes, both of which used to
# exit 0 with a green line and silently review on a v1 binary.

# Case A: a cached 1.x must NOT satisfy an unpinned request. "latest" is the
# documented default, and the old short-circuit accepted ANY cached version
# when nothing was pinned — so a self-hosted runner or developer box carrying
# v1 skipped the install entirely.
cached_case() {
  local name="$1" cached="$2" pin="$3" home bin
  home="$TMP/$name/home"; bin="$TMP/$name/bin"
  mkdir -p "$home" "$bin"
  printf '#!/bin/bash\necho "opencode %s"\n' "$cached" > "$bin/opencode"
  chmod +x "$bin/opencode"
  cp "$TMP/bin/curl" "$bin/curl"
  : > "$TMP/$name.github_path"
  env -i PATH="$bin:/usr/bin:/bin" HOME="$home" \
    GITHUB_PATH="$TMP/$name.github_path" STUB_CURL_LOG="$TMP/$name.curl" \
    OPENCODE_CLI_VERSION="$pin" bash "$INSTALLER" > "$TMP/$name.out" 2>&1
}

: > "$TMP/cached_v1.curl"
cached_case cached_v1 "1.18.31" "" || true
grep -q 'https://opencode.ai/v2/install' "$TMP/cached_v1.curl" \
  || fail "a cached 1.x satisfied an unpinned request — v2 was never installed"
grep -q 'predates v2' "$TMP/cached_v1.out" \
  || fail "replacing a cached v1 was not announced"
ok "a cached 1.x does not satisfy an unpinned request; v2 is installed over it"

: > "$TMP/cached_v2.curl"
cached_case cached_v2 "2.0.11" ""
grep -q 'found on PATH (version: 2.0.11)' "$TMP/cached_v2.out" \
  || fail "a cached v2 did not short-circuit the install"
if [ -s "$TMP/cached_v2.curl" ]; then
  fail "a cached v2 still re-downloaded the installer"
fi
ok "a cached v2 still short-circuits (no needless re-install)"

# Case B: a PACKAGE-managed v1 (brew/npm) can sit earlier on PATH than
# $HOME/.opencode/bin, so `opencode` may still resolve to v1 after a
# successful v2 install. The guide says remove it first; this lib cannot, so
# it must refuse rather than review on v1.
mkdir -p "$TMP/shadow/bin" "$TMP/shadow/home"
printf '#!/bin/bash\necho "opencode 1.18.31"\n' > "$TMP/shadow/bin/opencode"
chmod +x "$TMP/shadow/bin/opencode"
cat > "$TMP/shadow/bin/curl" <<'SHADOWCURL'
#!/bin/bash
# Succeeds, but the v1 binary earlier on PATH keeps shadowing it.
printf 'installed\n' >> "$STUB_CURL_LOG"
echo ":"
SHADOWCURL
chmod +x "$TMP/shadow/bin/curl"
if env -i PATH="$TMP/shadow/bin:/usr/bin:/bin" HOME="$TMP/shadow/home" \
  GITHUB_PATH="$TMP/shadow.github_path" STUB_CURL_LOG="$TMP/shadow.curl" \
  OPENCODE_CLI_VERSION="" bash "$INSTALLER" > "$TMP/shadow.out" 2>&1; then
  fail "a package-managed v1 shadowing the v2 install reported success"
fi
grep -q 'not a v2 release' "$TMP/shadow.out" \
  || fail "the shadowed-v1 failure did not name the problem"
grep -q 'migrate-v1' "$TMP/shadow.out" \
  || fail "the shadowed-v1 failure did not point at the migration guide"
ok "a package-managed v1 shadowing the install fails loudly, not green"

echo "All $pass install-opencode tests passed"
