#!/bin/bash
set -uo pipefail

# Test script for lib/redact-secrets.sh — the redaction pass run over the
# ai-analyse run artifact before it is uploaded (PR 179, review 5331608121
# finding 1). Offline; every "secret" below is a fake.

echo "=========================================="
echo "Testing secret redaction for run artifacts"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REDACT="$SCRIPT_DIR/lib/redact-secrets.sh"
ANALYSE_WF="$REPO_ROOT/.github/workflows/pipeline-ai-analyse.yml"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    fail=$((fail + 1))
  fi
}

[ -f "$REDACT" ] || { echo "❌ missing $REDACT"; exit 1; }

# Fakes built at run time so the literals never sit whole in this file.
GHP="ghp_$(printf 'A%.0s' $(seq 1 36))"
PAT="github_pat_$(printf 'B%.0s' $(seq 1 30))"
SKANT="sk-ant-$(printf 'c%.0s' $(seq 1 30))"
AKIA="AKIA$(printf 'D%.0s' $(seq 1 16))"
AIZA="AIza$(printf 'e%.0s' $(seq 1 35))"
XOX="xoxb-$(printf '1%.0s' $(seq 1 20))"
ENVKEY="envvalue-$(printf 'z%.0s' $(seq 1 12))"

D="$TMP_DIR/art"
mkdir -p "$D/decisions/out"
cat > "$D/analyse_prompt.md" <<EOF
Finding 3 quotes a token: $GHP in config.
A PAT $PAT and an Anthropic key $SKANT.
AWS id $AKIA, Google key $AIZA, Slack $XOX.
Authorization: Bearer abcdefghijklmnop0123456789
The provider key leaked into a log: $ENVKEY
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAfakefakefake
-----END RSA PRIVATE KEY-----
Ordinary text: sk-short, Bearer, ghp_ and the word token stay.
Short env value: abc
EOF
printf 'nested %s\n' "$GHP" > "$D/decisions/out/recommendations.md"

out="$(env OPENCODE_FAKE_API_KEY="$ENVKEY" SHORT_TOKEN=abc NOT_A_SECRET="$ENVKEY-x" bash "$REDACT" "$D" 2>&1)"
rc=$?
f="$D/analyse_prompt.md"
check "Test 1a: exits 0 and reports a count" "0|1" "$rc|$(printf '%s' "$out" | grep -c '2 file(s) redacted')"
check "Test 1b: every token shape is gone" "0" \
  "$(grep -cE 'ghp_A{20}|github_pat_B|sk-ant-c|AKIAD|AIzae|xoxb-1|abcdefghijklmnop0123|MIIEowIBAAKCAQEA' "$f" || true)"
check "Test 1c: an env var named like a secret has its exact value replaced" "0|1" \
  "$(grep -c "$ENVKEY" "$f" || true)|$(grep -c 'leaked into a log: <REDACTED>' "$f")"
check "Test 1d: the Bearer prefix and the PEM block collapse to <REDACTED>" "1|1|0" \
  "$(grep -c 'Authorization: Bearer <REDACTED>' "$f")|$(grep -cx '<REDACTED>' "$f")|$(grep -c 'PRIVATE KEY' "$f" || true)"
check "Test 1e: ordinary text and short values are untouched" "1|1" \
  "$(grep -c '^Ordinary text: sk-short, Bearer, ghp_ and the word token stay\.$' "$f")|$(grep -c '^Short env value: abc$' "$f")"
check "Test 1f: nested files are redacted too" "nested <REDACTED>" "$(cat "$D/decisions/out/recommendations.md")"
check "Test 1g: no secret value is printed" "0" \
  "$(printf '%s' "$out" | grep -cE "$ENVKEY|ghp_A|sk-ant" || true)"

# A value that is a prefix of another must not leave the tail behind: the
# longer value is replaced first.
printf 'x %s-longer y\n' "$ENVKEY" > "$TMP_DIR/p.md"; mkdir -p "$TMP_DIR/p"; mv "$TMP_DIR/p.md" "$TMP_DIR/p/"
env A_API_KEY="$ENVKEY" B_API_KEY="$ENVKEY-longer" bash "$REDACT" "$TMP_DIR/p" >/dev/null 2>&1
check "Test 2: the longest matching value wins" "x <REDACTED> y" "$(cat "$TMP_DIR/p/p.md")"

# Review 5331632755 finding 2: connection strings, from the environment and by
# shape — without redacting plain URLs.
C="$TMP_DIR/conn"; mkdir -p "$C"
DBURL="postgres://app:Sup3rSecretPw@db:5432/orders"
ADO="Server=db;User Id=sa;Password=Pa55w0rd-ado;"
cat > "$C/log.txt" <<EOF
env url: $DBURL
env ado: $ADO
shape: mysql://root:hunter2hunter@localhost/db
pairs: Pwd=plainpwd99; AccountKey=abcDEF123+/==; SharedAccessKey=zzzz9999
keep: https://github.com/org/repo and https://gateway.example/v1 and user@example.com
EOF
env DATABASE_URL="$DBURL" DB_CONNECTION_STRING="$ADO" GITHUB_SERVER_URL=https://github.com \
  OPENCODE_REVIEW_REPORT_OPENAI_URL=https://gateway.example/v1 bash "$REDACT" "$C" >/dev/null 2>&1
check "Test 5a: connection strings from the environment are replaced whole" "1|1" \
  "$(grep -c '^env url: <REDACTED>$' "$C/log.txt")|$(grep -c '^env ado: <REDACTED>$' "$C/log.txt")"
check "Test 5b: a URL's password and Password=/Pwd=/AccountKey= values go by shape" "1|1" \
  "$(grep -c '^shape: mysql://root:<REDACTED>@localhost/db$' "$C/log.txt")|$(grep -c '^pairs: Pwd=<REDACTED>; AccountKey=<REDACTED>; SharedAccessKey=<REDACTED>$' "$C/log.txt")"
check "Test 5c: plain URLs (even from *_URL variables) and e-mail addresses stay" "1" \
  "$(grep -c '^keep: https://github.com/org/repo and https://gateway.example/v1 and user@example.com$' "$C/log.txt")"

bash "$REDACT" "$TMP_DIR/missing" >/dev/null 2>&1
check "Test 3a: a missing directory exits 0" "0" "$?"
bash "$REDACT" >/dev/null 2>&1
check "Test 3b: no argument is a usage error" "64" "$?"

# The workflow redacts before uploading and uploads nothing when it cannot.
collect="$(awk '/- name: Collect ai-analyse run artifacts/{f=1} f && /- name: Upload ai-analyse run artifacts/{exit} f' "$ANALYSE_WF")"
check "Test 4: the Collect step redacts, and deletes the files when redaction is missing or fails" "1|1|1" \
  "$(printf '%s\n' "$collect" | grep -c 'redact="${REVIEW_SKILL_DIR:-}/scripts/lib/redact-secrets.sh"')|$(printf '%s\n' "$collect" | grep -c 'bash "\$redact" "\$run_dir"; then')|$(printf '%s\n' "$collect" | grep -c 'rm -rf "\$run_dir"')"

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Redaction tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Redaction tests passed ($pass checks)"
echo "=========================================="
