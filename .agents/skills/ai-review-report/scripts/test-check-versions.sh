#!/bin/bash
# test-check-versions.sh — regression tests for lib/check-versions.sh.
#
# Runs fully offline: `opencode` / `code-review-graph` / `rtk` and `curl` are
# stubbed on PATH, and the registries are fixture directories. The stub curl
# records every requested URL so the tests can assert *which* package was
# looked up — the original bug was a lookup against `registry.npmjs.org/opencode`,
# which 404s (the CLI publishes as `opencode-ai`), so the header silently
# rendered "✅ up to date" while an update was available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/check-versions.sh"
AGGREGATOR="${SCRIPT_DIR}/aggregate-reviews.sh"
RUN_REVIEW="${SCRIPT_DIR}/run-review.sh"

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

# code-review-graph and rtk are absent from PATH by default (mirrors "graph
# analysis disabled" / "RTK disabled" / "not installed"). Tests that need
# either present prepend their own stub dir to PATH.

# Fixture registry: curl -sf --max-time N <url>. The last argument is the URL;
# it maps to $STUB_REGISTRY_DIR/<domain-stripped path with / → _>.json. A
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
# npm latest: .../<pkg>/latest → <pkg>_latest.json
write_npm_pkg() { printf '{"version":"%s"}\n' "$2" > "${registry_dir}/${1}_latest.json"; }
# PyPI JSON API: .../pypi/<pkg>/json → pypi_<pkg>_json.json (registry base
# already includes the /pypi segment, matching the real pypi.org/pypi shape).
write_pypi_pkg() { printf '{"info":{"version":"%s"}}\n' "$2" > "${registry_dir}/pypi_${1}_json.json"; }
# GitHub Releases API: .../repos/<owner>/<repo>/releases/latest →
# repos_<owner>_<repo>_releases_latest.json.
write_github_release() { printf '{"tag_name":"%s"}\n' "$2" > "${registry_dir}/repos_${1//\//_}_releases_latest.json"; }

fake_home="${tmp_dir}/home"
mkdir -p "${fake_home}"

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
    GRAPH_PYPI_REGISTRY="https://pypi.example.test/pypi" \
    RTK_GITHUB_API="https://api.example.test" \
    "$@" \
    bash -c '
      set -euo pipefail
      . "$1"
      printf "%s" "${OPENCODE_VERSION_INFO:-}"   > "$2.info"
      printf "%s" "${OPENCODE_VERSION_FOOTER:-}" > "$2.footer"
      { declare -p _cv_have_jq 2>/dev/null
        declare -F _cv_npm_latest _cv_pypi_latest _cv_github_latest_tag _cv_is_newer 2>/dev/null; } > "$2.leaks" || true
    ' _ "$LIB" "${tmp_dir}/${name}" >/dev/null
}

echo "=========================================="
echo "Testing opencode CLI package name + update detection"
echo "=========================================="

write_npm_pkg "opencode-ai" "1.18.10"

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
echo "Testing code-review-graph resolution"
echo "=========================================="

# code-review-graph absent from PATH (graph analysis disabled or install
# failed) — no graph line should render, and no PyPI lookup should happen.
run_check graph_absent STUB_OPENCODE_VERSION=1.18.10
grep -q 'code-review-graph' "${tmp_dir}/graph_absent.info" \
  && fail "graph line rendered even though code-review-graph is not on PATH"
grep -q 'pypi' "${tmp_dir}/graph_absent.curl.log" \
  && fail "PyPI was queried even though code-review-graph is not installed"
ok "no graph line and no PyPI lookup when code-review-graph is absent"

# code-review-graph present, update available.
graph_bin="${tmp_dir}/graph_bin"
mkdir -p "$graph_bin"
cat > "${graph_bin}/code-review-graph" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && echo "${STUB_GRAPH_VERSION:-2.0.0}"
STUB
chmod +x "${graph_bin}/code-review-graph"
write_pypi_pkg "code-review-graph" "2.5.0"

run_check graph_update_available \
  STUB_OPENCODE_VERSION=1.18.10 \
  STUB_GRAPH_VERSION=2.4.0 \
  PATH="${graph_bin}:${stub_bin}:/usr/bin:/bin"
grep -q '/code-review-graph/json$' "${tmp_dir}/graph_update_available.curl.log" \
  || fail "graph lookup did not request code-review-graph/json from PyPI"
ok "graph version is looked up on PyPI under the 'code-review-graph' package"

grep -q 'code-review-graph.*⬆️\|⬆️.*code-review-graph' "${tmp_dir}/graph_update_available.info" \
  || fail "no update marker for code-review-graph 2.4.0 → 2.5.0"
grep -q 'v2.4.0' "${tmp_dir}/graph_update_available.info" || fail "current graph version missing from header"
grep -q 'v2.5.0' "${tmp_dir}/graph_update_available.info" || fail "latest graph version missing from header"
grep -q 'OPENCODE_REVIEW_REPORT_GRAPH_VERSION' "${tmp_dir}/graph_update_available.info" \
  || fail "graph update notice does not name the Variable to bump"
ok "header announces an available code-review-graph update and names the Variable"

run_check graph_up_to_date \
  STUB_OPENCODE_VERSION=1.18.10 \
  STUB_GRAPH_VERSION=2.5.0 \
  PATH="${graph_bin}:${stub_bin}:/usr/bin:/bin"
grep -q 'code-review-graph' "${tmp_dir}/graph_up_to_date.info" \
  || fail "graph line missing when code-review-graph is installed"
grep -q 'code-review-graph.*⬆️\|⬆️.*code-review-graph' "${tmp_dir}/graph_up_to_date.info" \
  && fail "false update notice for code-review-graph when current == latest"
ok "code-review-graph current == latest renders ✅ and no update notice"

echo ""
echo "=========================================="
echo "Testing rtk resolution"
echo "=========================================="

# rtk absent from PATH (RTK disabled or install failed) — no rtk line should
# render, and no GitHub Releases lookup should happen.
run_check rtk_absent STUB_OPENCODE_VERSION=1.18.10
grep -q '\*\*rtk:\*\*' "${tmp_dir}/rtk_absent.info" \
  && fail "rtk line rendered even though rtk is not on PATH"
grep -q 'releases/latest' "${tmp_dir}/rtk_absent.curl.log" \
  && fail "GitHub was queried even though rtk is not installed"
ok "no rtk line and no GitHub lookup when rtk is absent"

# rtk present, update available.
rtk_bin="${tmp_dir}/rtk_bin"
mkdir -p "$rtk_bin"
cat > "${rtk_bin}/rtk" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && echo "rtk ${STUB_RTK_VERSION:-0.40.0}"
STUB
chmod +x "${rtk_bin}/rtk"
write_github_release "rtk-ai/rtk" "0.44.1"

run_check rtk_update_available \
  STUB_OPENCODE_VERSION=1.18.10 \
  STUB_RTK_VERSION=0.44.0 \
  PATH="${rtk_bin}:${stub_bin}:/usr/bin:/bin"
grep -q '/repos/rtk-ai/rtk/releases/latest$' "${tmp_dir}/rtk_update_available.curl.log" \
  || fail "rtk lookup did not request the rtk-ai/rtk GitHub releases/latest endpoint"
ok "rtk version is looked up on GitHub under the 'rtk-ai/rtk' repo"

grep -q 'rtk.*⬆️\|⬆️.*rtk' "${tmp_dir}/rtk_update_available.info" \
  || fail "no update marker for rtk 0.44.0 → 0.44.1"
grep -q 'v0.44.0' "${tmp_dir}/rtk_update_available.info" || fail "current rtk version missing from header"
grep -q 'v0.44.1' "${tmp_dir}/rtk_update_available.info" || fail "latest rtk version missing from header"
grep -q 'OPENCODE_REVIEW_REPORT_RTK_VERSION' "${tmp_dir}/rtk_update_available.info" \
  || fail "rtk update notice does not name the Variable to bump"
ok "header announces an available rtk update and names the Variable"

# opencode CLI is current in this run (STUB_OPENCODE_VERSION=1.18.10 == the
# npm fixture) and code-review-graph is absent, so nothing has claimed the
# footer before rtk's block runs — rtk should take it over.
grep -q '→' "${tmp_dir}/rtk_update_available.footer" || fail "footer missing the rtk update arrow"
grep -q 'rtk' "${tmp_dir}/rtk_update_available.footer" || fail "footer did not fall through to rtk's update notice"
ok "rtk's update notice claims the footer when nothing else has"

run_check rtk_up_to_date \
  STUB_OPENCODE_VERSION=1.18.10 \
  STUB_RTK_VERSION=0.44.1 \
  PATH="${rtk_bin}:${stub_bin}:/usr/bin:/bin"
grep -q '\*\*rtk:\*\*' "${tmp_dir}/rtk_up_to_date.info" \
  || fail "rtk line missing when rtk is installed"
grep -q 'rtk.*⬆️\|⬆️.*rtk' "${tmp_dir}/rtk_up_to_date.info" \
  && fail "false update notice for rtk when current == latest"
ok "rtk current == latest renders ✅ and no update notice"

echo ""
echo "=========================================="
echo "Testing best-effort degradation"
echo "=========================================="

rm -f "${registry_dir}/opencode-ai_latest.json"
run_check registry_down STUB_OPENCODE_VERSION=1.18.9
grep -q '✅' "${tmp_dir}/registry_down.info" || fail "unreachable registry should still report the installed version"
grep -q '⬆️' "${tmp_dir}/registry_down.info" && fail "unreachable registry must not invent an update"
ok "unreachable npm registry degrades to installed-version-only, never blocks the review"
write_npm_pkg "opencode-ai" "1.18.10"

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
echo "Testing aggregate-reviews.sh + run-review.sh wiring"
echo "=========================================="

grep -q 'OPENCODE_VERSION_FOOTER="\${10:-}"' "$AGGREGATOR" \
  || fail "aggregate-reviews.sh does not accept the footer as \$10"
ok "aggregate-reviews.sh reads the footer from \$10"

grep -q '"\${OPENCODE_VERSION_FOOTER:-}"' "$RUN_REVIEW" \
  || fail "run-review.sh does not pass OPENCODE_VERSION_FOOTER to the aggregator"
ok "run-review.sh forwards the footer to the aggregator"

grep -q 'graph_analysis_available' "$RUN_REVIEW" > /tmp/_graph_line_no.txt
graph_output_line=$(grep -n 'echo "graph_analysis_available=' "$RUN_REVIEW" | head -1 | cut -d: -f1)
check_versions_line=$(grep -n '\. "\$LIB_DIR/check-versions.sh"' "$RUN_REVIEW" | head -1 | cut -d: -f1)
[ -n "$graph_output_line" ] && [ -n "$check_versions_line" ] \
  || fail "could not locate graph-analysis-available write or check-versions.sh source line"
[ "$check_versions_line" -gt "$graph_output_line" ] \
  || fail "check-versions.sh must be sourced AFTER graph analysis completes, so 'code-review-graph --version' reflects what build-code-graph.sh installed"
ok "check-versions.sh runs after graph analysis (Step 13.5), not before opencode install probing"

rtk_install_line=$(grep -n 'bash "\$LIB_DIR/install-rtk.sh"' "$RUN_REVIEW" | head -1 | cut -d: -f1)
[ -n "$rtk_install_line" ] || fail "could not locate the install-rtk.sh call site"
[ "$check_versions_line" -gt "$rtk_install_line" ] \
  || fail "check-versions.sh must be sourced AFTER install-rtk.sh runs, so 'rtk --version' reflects what was actually installed"
ok "check-versions.sh runs after rtk install (step 5c-bis)"

echo ""
echo "=========================================="
echo "✅ All ${pass_count} check-versions tests passed"
echo "=========================================="
