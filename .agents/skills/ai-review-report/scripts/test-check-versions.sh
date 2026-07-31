#!/bin/bash
# test-check-versions.sh — regression tests for lib/check-versions.sh.
#
# Runs fully offline: `opencode` and `curl` are stubbed on PATH, and the
# registry is a fixture directory. The stub curl records every requested URL so
# the tests can assert *which* package was looked up — the original bug was a
# lookup against `registry.npmjs.org/opencode`, which 404s (the CLI publishes as
# `opencode-ai`), so the header silently rendered "✅ up to date" while an
# update was available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/check-versions.sh"
AGGREGATOR="${SCRIPT_DIR}/aggregate-reviews.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass_count=0
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }
ok()   { pass_count=$((pass_count + 1)); echo "  ✅ $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq is required to run these tests (and by check-versions.sh itself)." >&2
  exit 1
fi

# --- stubs --------------------------------------------------------------------
stub_bin="${tmp_dir}/bin"
mkdir -p "$stub_bin"

cat > "${stub_bin}/opencode" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && echo "${STUB_OPENCODE_VERSION:-1.0.0}"
STUB

# Fixture registry: curl -sf --max-time N <url>. The last argument is the URL;
# it maps to $STUB_REGISTRY_DIR/<percent-decoded path with / → _>.json. A
# missing fixture exits 22, exactly as `curl -sf` does on a 404.
cat > "${stub_bin}/curl" <<'STUB'
#!/bin/bash
url="${!#}"
echo "$url" >> "$STUB_CURL_LOG"
path="${url#*://}"; path="${path#*/}"
key="$(printf '%s' "$path" | sed 's/%2F/_/g; s#/#_#g')"
fixture="${STUB_REGISTRY_DIR}/${key}.json"
[ -f "$fixture" ] || exit 22
cat "$fixture"
STUB

chmod +x "${stub_bin}/opencode" "${stub_bin}/curl"

registry_dir="${tmp_dir}/registry"
mkdir -p "$registry_dir"
write_pkg() { printf '{"version":"%s"}\n' "$2" > "${registry_dir}/${1}_latest.json"; }

# Fixture opencode.json — a sentinel npm name proves the mapping is read from
# the installed config rather than a hardcoded table inside the script.
fake_home="${tmp_dir}/home"
mkdir -p "${fake_home}/.config/opencode"
cat > "${fake_home}/.config/opencode/opencode.json" <<'JSON'
{
  "provider": {
    "gemini":  { "npm": "@ai-sdk/google" },
    "openai":  { "npm": "@sentinel/from-config" }
  }
}
JSON

# run_check <name> [VAR=VAL ...] — source the lib in a clean subshell and dump
# the rendered strings to ${tmp_dir}/<name>.{info,footer,log}.
run_check() {
  local name="$1"; shift
  local log="${tmp_dir}/${name}.curl.log"
  : > "$log"
  env -i \
    PATH="${stub_bin}:/usr/bin:/bin" \
    HOME="$fake_home" \
    STUB_REGISTRY_DIR="$registry_dir" \
    STUB_CURL_LOG="$log" \
    OPENCODE_NPM_REGISTRY="https://registry.example.test" \
    "$@" \
    bash -c '
      set -euo pipefail
      . "$1"
      printf "%s" "${OPENCODE_VERSION_INFO:-}"   > "$2.info"
      printf "%s" "${OPENCODE_VERSION_FOOTER:-}" > "$2.footer"
      { declare -p _cv_have_jq _cv_provider_id _cv_config 2>/dev/null
        declare -F _cv_npm_latest _cv_is_newer 2>/dev/null; } > "$2.leaks" || true
    ' _ "$LIB" "${tmp_dir}/${name}" >/dev/null
}

echo "=========================================="
echo "Testing opencode CLI package name + update detection"
echo "=========================================="

write_pkg "opencode-ai" "1.18.10"
write_pkg "@ai-sdk_google" "4.0.29"

run_check update_available STUB_OPENCODE_VERSION=1.18.9
grep -q '/opencode-ai/latest$' "${tmp_dir}/update_available.curl.log" \
  || fail "CLI lookup did not request opencode-ai (regression: 'opencode' 404s on npm)"
ok "CLI version is looked up under the 'opencode-ai' npm package"

grep -q '⬆️' "${tmp_dir}/update_available.info" || fail "no update marker for 1.18.9 → 1.18.10"
grep -q 'v1.18.9' "${tmp_dir}/update_available.info" || fail "current version missing from header"
grep -q 'v1.18.10' "${tmp_dir}/update_available.info" || fail "latest version missing from header"
ok "header announces an available CLI update"

grep -q 'OPENCODE_REVIEW_REPORT_CLI_VERSION' "${tmp_dir}/update_available.info" \
  || fail "update notice does not name the Variable to bump"
ok "update notice names OPENCODE_REVIEW_REPORT_CLI_VERSION"

grep -q '→' "${tmp_dir}/update_available.footer" || fail "footer missing the update arrow"
ok "footer is rendered (regression: it read unexported vars in a child process)"

run_check up_to_date STUB_OPENCODE_VERSION=1.18.10
grep -q '✅' "${tmp_dir}/up_to_date.info" || fail "no up-to-date marker when current == latest"
grep -q '⬆️' "${tmp_dir}/up_to_date.info" && fail "false update notice when current == latest"
grep -q '→' "${tmp_dir}/up_to_date.footer" && fail "footer claims an update when current == latest"
ok "current == latest renders ✅ and no update notice"

# A pin ahead of the registry must not read as "update available" — the
# original `!=` comparison would have announced a downgrade.
run_check pin_ahead STUB_OPENCODE_VERSION=1.19.0
grep -q '⬆️' "${tmp_dir}/pin_ahead.info" && fail "bogus update notice when the pin is ahead of npm latest"
grep -q '✅' "${tmp_dir}/pin_ahead.info" || fail "pin ahead of latest should still render ✅"
ok "a pin ahead of npm latest does not render a bogus update notice"

echo ""
echo "=========================================="
echo "Testing provider package resolution"
echo "=========================================="

run_check provider_default STUB_OPENCODE_VERSION=1.18.10
grep -q '@ai-sdk/google' "${tmp_dir}/provider_default.info" \
  || fail "provider line missing; expected the gemini default"
ok "provider-id defaults to gemini (matches run-review.sh's :-gemini guards)"

write_pkg "@sentinel_from-config" "9.9.9"
run_check provider_from_config \
  STUB_OPENCODE_VERSION=1.18.10 \
  OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai
grep -q '@sentinel/from-config' "${tmp_dir}/provider_from_config.info" \
  || fail "provider npm name was not read from the installed opencode.json"
ok "provider npm name comes from opencode.json (single source of truth, no duplicated map)"

grep -q '@sentinel%2Ffrom-config/latest$' "${tmp_dir}/provider_from_config.curl.log" \
  || fail "scoped package name was not percent-encoded in the registry URL"
ok "scoped provider packages are percent-encoded for the registry"

grep -q 'v9.9.9' "${tmp_dir}/provider_from_config.info" || fail "provider latest version missing"
grep -q '⬆️' "${tmp_dir}/provider_from_config.info" \
  && fail "provider line must not claim an update — the SDK is bundled in the CLI binary"
ok "provider line is informational (no unreachable current-vs-latest branch)"

echo ""
echo "=========================================="
echo "Testing best-effort degradation"
echo "=========================================="

rm -f "${registry_dir}/opencode-ai_latest.json"
run_check registry_down STUB_OPENCODE_VERSION=1.18.9
grep -q '✅' "${tmp_dir}/registry_down.info" || fail "unreachable registry should still report the installed version"
grep -q '⬆️' "${tmp_dir}/registry_down.info" && fail "unreachable registry must not invent an update"
ok "unreachable registry degrades to installed-version-only, never blocks the review"
write_pkg "opencode-ai" "1.18.10"

cat > "${stub_bin}/opencode" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "${stub_bin}/opencode"
run_check no_cli
[ -s "${tmp_dir}/no_cli.info" ] && fail "header must be empty when the CLI version is unknown"
[ -s "${tmp_dir}/no_cli.footer" ] && fail "footer must be empty when the CLI version is unknown"
ok "unknown CLI version renders nothing (report is byte-identical to pre-feature)"

echo ""
echo "=========================================="
echo "Testing sourced-script hygiene"
echo "=========================================="

[ -s "${tmp_dir}/update_available.leaks" ] \
  && fail "temporaries leaked into the caller's shell: $(cat "${tmp_dir}/update_available.leaks")"
ok "no _cv_* variables or helper functions leak into the sourcing shell"

echo ""
echo "=========================================="
echo "Testing aggregate-reviews.sh wiring"
echo "=========================================="

grep -q 'OPENCODE_VERSION_FOOTER="\${10:-}"' "$AGGREGATOR" \
  || fail "aggregate-reviews.sh does not accept the footer as \$10"
ok "aggregate-reviews.sh reads the footer from \$10"

grep -q 'OPENCODE_CLI_CURRENT_VERSION\|OPENCODE_CLI_LATEST_VERSION' "$AGGREGATOR" \
  && fail "aggregate-reviews.sh reads env vars that are never exported to it (dead code)"
ok "aggregate-reviews.sh no longer reads unexported version vars"

grep -q '"\${OPENCODE_VERSION_FOOTER:-}"' "${SCRIPT_DIR}/run-review.sh" \
  || fail "run-review.sh does not pass OPENCODE_VERSION_FOOTER to the aggregator"
ok "run-review.sh forwards the footer to the aggregator"

echo ""
echo "=========================================="
echo "✅ All ${pass_count} check-versions tests passed"
echo "=========================================="
