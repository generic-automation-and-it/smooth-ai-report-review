#!/bin/bash
# test-install-rtk.sh — regression tests for lib/install-rtk.sh.
#
# Runs fully offline: `curl` and the upstream install.sh it pipes to are
# stubbed on PATH. The stub records the RTK_VERSION env var the piped script
# actually saw — the original bug was passing the `v`-stripped
# OPENCODE_TOOL_RTK_VERSION straight through as RTK_VERSION, but
# rtk's release tags (and its install.sh's download-URL construction) require
# the leading `v` (e.g. `v0.44.1`, not `0.44.1`), so every pinned install
# 404'd and silently degraded to "RTK unavailable" (confirmed live against
# github.com/rtk-ai/rtk: the bare-digit URL 404s, the `v`-prefixed one 302s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/install-rtk.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass_count=0
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }
ok()   { pass_count=$((pass_count + 1)); echo "  ✅ $*"; }

stub_bin="${tmp_dir}/bin"
mkdir -p "$stub_bin"

# Stub curl: when asked for the rtk install.sh, emit a tiny fake installer to
# stdout (piped straight to `sh` by install-rtk.sh) that records whatever
# RTK_VERSION it was invoked with, then drops a working `rtk` stub on PATH so
# the rest of install-rtk.sh (PATH repair, version verify, `rtk init`) has
# something real to call. Any other curl invocation (e.g. the OpenCode plugin
# init doing its own network calls) is a no-op success.
cat > "${stub_bin}/curl" <<'STUB'
#!/bin/bash
url="${!#}"
if [[ "$url" == *"install.sh"* ]]; then
  cat <<'INNER'
#!/bin/sh
echo "RTK_VERSION_SEEN=${RTK_VERSION:-<unset>}" >> "$RTK_TEST_LOG"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/rtk" <<'RTKSTUB'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then
  echo "rtk ${STUB_INSTALLED_VERSION:-0.44.1}"
else
  exit 0
fi
RTKSTUB
chmod +x "$HOME/.local/bin/rtk"
INNER
  exit 0
fi
exit 0
STUB
chmod +x "${stub_bin}/curl"

run_install() {
  local name="$1"; shift
  local log="${tmp_dir}/${name}.log"
  : > "$log"
  local home_dir="${tmp_dir}/${name}_home"
  mkdir -p "$home_dir"
  env -i \
    PATH="${stub_bin}:/usr/bin:/bin" \
    HOME="$home_dir" \
    RTK_TEST_LOG="$log" \
    GITHUB_PATH=/dev/null \
    STUB_INSTALLED_VERSION="0.44.1" \
    "$@" \
    bash "$LIB" > "${tmp_dir}/${name}.stdout" 2>&1
}

echo "=========================================="
echo "Testing pinned-version tag prefix (regression)"
echo "=========================================="

run_install pinned OPENCODE_TOOL_RTK_VERSION="0.44.1"
grep -q '^RTK_VERSION_SEEN=v0.44.1$' "${tmp_dir}/pinned.log" \
  || fail "upstream install.sh did not see the v-prefixed tag (got: $(cat "${tmp_dir}/pinned.log" 2>/dev/null))"
ok "a bare-digit pin (0.44.1) is re-prefixed with 'v' before reaching rtk's installer"

run_install pinned_v OPENCODE_TOOL_RTK_VERSION="v0.44.1"
grep -q '^RTK_VERSION_SEEN=v0.44.1$' "${tmp_dir}/pinned_v.log" \
  || fail "an already-v-prefixed pin was double-prefixed or mangled (got: $(cat "${tmp_dir}/pinned_v.log" 2>/dev/null))"
ok "a v-prefixed pin (v0.44.1) is not double-prefixed"

grep -q '✓ rtk ready (version: 0.44.1)' "${tmp_dir}/pinned.stdout" \
  || fail "install-rtk.sh did not report success after a pinned install (stdout: $(cat "${tmp_dir}/pinned.stdout"))"
ok "pinned install completes and verifies the installed version"

echo ""
echo "=========================================="
echo "Testing unpinned (latest) install"
echo "=========================================="

run_install latest
grep -q '^RTK_VERSION_SEEN=<unset>$' "${tmp_dir}/latest.log" \
  || fail "RTK_VERSION should be unset for an unpinned install, letting rtk's installer resolve latest itself (got: $(cat "${tmp_dir}/latest.log" 2>/dev/null))"
ok "an unpinned (latest) install does not set RTK_VERSION, matching rtk's own latest-resolution logic"

echo ""
echo "=========================================="
echo "✅ All ${pass_count} install-rtk tests passed"
echo "=========================================="
