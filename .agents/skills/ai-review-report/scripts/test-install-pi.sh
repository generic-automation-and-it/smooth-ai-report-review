#!/bin/bash
# L1: install-pi.sh honours the pin, the floor, the Node requirement and PATH.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
INSTALLER="$SCRIPT_DIR/lib/install-pi.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass + 1)); }
fail() { echo "  ❌ $1"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/node" <<'NODE'
#!/bin/bash
if [ "${1:-}" = "-e" ]; then
  IFS=. read -r a b _ <<< "${NODE_VERSION:-22.23.4}"
  if [ "$a" -gt 22 ] || { [ "$a" -eq 22 ] && [ "$b" -ge 19 ]; }; then exit 0; else exit 1; fi
fi
echo "v${NODE_VERSION:-22.23.4}"
NODE
cat > "$TMP/bin/npm" <<'NPM'
#!/bin/bash
if [ "${1:-}" = "prefix" ]; then echo "${NPM_PREFIX:?}"; exit 0; fi
printf '%s\n' "$*" >> "${NPM_LOG:?}"
case "$*" in
  install*)
    mkdir -p "${NPM_PREFIX:?}/bin"
    printf '#!/bin/bash\necho "%s"\n' "${INSTALLED_VERSION:-1.5.2}" > "$NPM_PREFIX/bin/pi"
    chmod +x "$NPM_PREFIX/bin/pi"
    ;;
esac
exit 0
NPM
chmod +x "$TMP/bin/node" "$TMP/bin/npm"

run_install() { # run_install <cached-version|""> <pin> <env...>
  local cached="$1" pin="$2"; shift 2
  local cache="$TMP/cache" prefix="$TMP/prefix"
  rm -rf "$cache" "$prefix"; mkdir -p "$cache" "$prefix"
  if [ -n "$cached" ]; then
    printf '#!/bin/bash\necho "%s"\n' "$cached" > "$cache/pi"; chmod +x "$cache/pi"
  fi
  : > "$prefix.github_path"; : > "$TMP/npm.log"
  env -i PATH="$cache:$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" \
    NODE_VERSION="${NODE_VERSION:-22.23.4}" NPM_PREFIX="$prefix" \
    NPM_LOG="$TMP/npm.log" INSTALLED_VERSION="${INSTALLED_VERSION:-1.5.2}" \
    GITHUB_PATH="$prefix.github_path" OPENCODE_TOOL_PI_VERSION="$pin" "$@" \
    bash "$INSTALLER" > "$TMP/out.log" 2>&1
  rc=$?
  NPM_CALLS="${NPM_LOG:-}"
  printf '%s' "$rc"
}

check() { # check <label> <expected> <actual>
  if [ "$3" = "$2" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

echo "=========================================="
echo "Testing install-pi.sh (LADR-125)"
echo "=========================================="

check "exact pin at the floor installs that version" "0" "$(run_install "" 1.5.2)"
grep -q '@earendil-works/pi-coding-agent@1.5.2' "$TMP/npm.log" 2>/dev/null \
  && ok "the exact pin reaches npm" || fail "the exact pin did not reach npm"

check "a leading v is accepted" "0" "$(run_install "" v1.5.2)"
grep -q '@earendil-works/pi-coding-agent@1.5.2' "$TMP/npm.log" 2>/dev/null \
  && ok "the leading v is stripped before npm" || fail "the leading v was not stripped"

check "a pin below the floor is rejected" "1" "$(run_install "" 1.4.9)"
grep -q 'below the supported pi floor' "$TMP/out.log" && ok "the floor rejection is named" || fail "floor rejection message missing"

check "a garbage pin is rejected" "1" "$(run_install "" not-a-version)"

check "a cached pi at the floor is reused for a blank pin" "0" "$(run_install 1.5.2 "")"
grep -q 'pi found on PATH' "$TMP/out.log" && ok "the cache hit is announced" || fail "cache hit not announced"

check "a cached pi below the floor is rejected" "1" "$(run_install 1.4.0 "")"
grep -q 'below the supported floor' "$TMP/out.log" && ok "cached-below-floor rejection is named" || fail "cached-below-floor message missing"

check "a blank pin with no pi installs latest" "0" "$(run_install "" "")"
grep -q '@earendil-works/pi-coding-agent$' "$TMP/npm.log" 2>/dev/null \
  && ok "latest installs without a version suffix" || fail "latest install did not reach npm"

NODE_VERSION=20.11.1 check "Node below 22.19 is rejected before install" "1" "$(NODE_VERSION=20.11.1 run_install "" 1.5.2)"
grep -q 'Node.js 22.19.0 or newer' "$TMP/out.log" && ok "the Node failure names the floor" || fail "Node failure message missing"

run_install "" 1.5.2 >/dev/null
GP="$TMP/prefix.github_path"
[ -s "$GP" ] && ok "GITHUB_PATH gains the npm bin directory" || fail "GITHUB_PATH was not updated"

# Only lib/install-pi.sh may install pi.
offenders=""
while IFS= read -r f; do
  case "$f" in
    *install-pi.sh|*CHANGELOG*|*AGENTS.md|*README.md|*pi-runtime.md) continue ;;
  esac
  if grep -qE 'pi\.dev/install\.sh|npm install -g [^#]*@earendil-works/pi-coding-agent' "$f" 2>/dev/null; then
    offenders="${offenders}${f}"$'\n'
  fi
done < <(find "$REPO_ROOT/.agents/skills" "$REPO_ROOT/.github/workflows" "$REPO_ROOT/docs/examples" -type f 2>/dev/null | grep -E '\.(sh|ya?ml)$')
check "no raw pi install outside lib/install-pi.sh" "" "$offenders"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All install-pi tests passed"; else echo "$fail install-pi test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
