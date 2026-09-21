#!/bin/bash
# Offline regression tests for the shared OpenCode v2 installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/lib/install-opencode.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
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
# The cached binary lives where the v2 installer WRITES — $HOME/.opencode/bin —
# so the install genuinely replaces it. The first version of this helper put the
# shim in a separate bin dir earlier on PATH, which is the SHADOWING scenario
# (covered separately below), not the cached one; the two were conflated and the
# exit code then had to be swallowed with `|| true` to make the case pass, which
# masked the very migration failure the test claims to guard.
cached_case() {
  local name="$1" cached="$2" pin="$3" home bin
  home="$TMP/$name/home"; bin="$home/.opencode/bin"
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
cached_case cached_v1 "1.18.31" "" \
  || fail "replacing a cached v1 must SUCCEED — the v2 installer overwrites \$HOME/.opencode/bin/opencode, so this is the migration path itself, not a shadowed install"
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

# --- No raw install curl outside the shared lib (LADR-048) ------------------
# The install-source-of-truth Non-Negotiable was violated in FIVE places across
# this migration — README, local-review.sh twice, run-evals.sh — and each was
# found by hand, one review round at a time, because nothing asserted it. The
# rule is mechanical, so assert it mechanically.
#
# Allowed to contain the URL: the shared installer itself, this test's own
# assertions, and prose in docs/changelogs describing what the installer does.
# Only complain when the URL is being handed to a shell, not merely named.
# The pipeline is matched after joining shell continuations — a trailing `\`
# and a trailing `|` both continue the command onto the next line — because a
# per-line grep let `curl … \` / `| bash` split across lines read as "no raw
# installer" and silently defeat the contract (review 5263417133, finding 2).
# Only those two joins are applied, not a whole-file flatten: flattening would
# let a `curl` in one step, the URL in a comment, and a `| bash` in another
# step match as one pipeline.
_is_raw_install() { # _is_raw_install <file>
  sed -e ':a' -e '/\\[[:space:]]*$/{N; s/\\[[:space:]]*\n[[:space:]]*/ /; ba}' \
      -e '/|[[:space:]]*$/{N; s/|[[:space:]]*\n[[:space:]]*/| /; ba}' "$1" \
    | grep -qE 'curl[^|]*opencode\.ai/v2/install[^|]*\|[[:space:]]*(ba)?sh'
}
_curl_offenders() {
  grep -rln 'opencode\.ai/v2/install' \
    --include='*.sh' --include='*.yml' --include='*.yaml' \
    "$SCRIPT_DIR" "$REPO_ROOT/.github" "$REPO_ROOT/.docs" 2>/dev/null \
    | grep -v 'lib/install-opencode\.sh$' \
    | grep -v 'test-install-opencode\.sh$' \
    | while IFS= read -r f; do
        _is_raw_install "$f" && printf '%s ' "$f"
      done
}

# The matcher itself, against fixtures, so a multiline pipeline cannot slip
# past it again unnoticed. Positive shapes: one line, backslash-continued,
# pipe at end of line. Negative shapes: the URL merely named in a comment, a
# curl and a bash on separate statements, and a delegation to the shared lib.
mkdir -p "$TMP/rawfix"
printf 'curl -fsSL https://opencode.ai/v2/install | bash\n' > "$TMP/rawfix/one-line.sh"
printf 'curl -fsSL \\\n  https://opencode.ai/v2/install \\\n  | bash\n' > "$TMP/rawfix/backslash.sh"
printf 'run: |\n  curl -fsSL https://opencode.ai/v2/install |\n    bash\n' > "$TMP/rawfix/pipe-eol.yml"
printf '# the shared lib wraps https://opencode.ai/v2/install with a version pin\nbash lib/install-opencode.sh\n' > "$TMP/rawfix/comment.sh"
printf 'curl -fsSL https://example.com/x -o /tmp/x\n# see https://opencode.ai/v2/install\necho done | bash -c cat\n' > "$TMP/rawfix/separate.sh"
for _f in one-line.sh backslash.sh pipe-eol.yml; do
  _is_raw_install "$TMP/rawfix/$_f" || fail "raw-install matcher missed $_f"
done
for _f in comment.sh separate.sh; do
  _is_raw_install "$TMP/rawfix/$_f" && fail "raw-install matcher false-matched $_f"
done
ok "raw-install matcher catches multiline pipelines and ignores mere mentions"
_offenders="$(_curl_offenders || true)"
[ -z "$_offenders" ] || fail "raw install curl outside the shared lib (LADR-048): ${_offenders}"
ok "no raw install curl outside lib/install-opencode.sh"

echo "All $pass install-opencode tests passed"
