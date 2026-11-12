#!/bin/bash
# Offline regression test for copilot-review.sh detect — the selected review's
# author decides the route; the PR-wide scan is a legacy fallback only.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/copilot-review.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✅ $name"
    pass=$((pass + 1))
  else
    echo "  ❌ $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    fail=$((fail + 1))
  fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    *"/pulls/1/reviews/9")  echo 'Copilot'; exit 0 ;;
    *"/pulls/1/reviews/10") echo 'github-actions[bot]'; exit 0 ;;
    *"/pulls/1/reviews")    printf 'github-actions[bot]\nCopilot\n'; exit 0 ;;
    *"/pulls/1/comments")   echo 'someone'; exit 0 ;;
    *"/pulls/2/reviews")    echo 'github-actions[bot]'; exit 0 ;;
    *"/pulls/2/comments")   echo 'copilot-pull-request-reviewer[bot]'; exit 0 ;;
    *"/pulls/3/reviews")    echo 'github-actions[bot]'; exit 0 ;;
    *"/pulls/3/comments")   echo 'someone'; exit 0 ;;
  esac
done
STUB
chmod +x "$TMP/bin/gh"

run_detect() {
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" detect "$@"
}

check "selected Copilot review routes to COPILOT" "COPILOT" "$(run_detect 1 9)"
check "selected non-Copilot review routes to OTHER despite Copilot history" "OTHER" "$(run_detect 1 10)"
check "legacy scan still finds a Copilot review" "COPILOT" "$(run_detect 1)"
check "legacy scan finds a Copilot inline comment" "COPILOT" "$(run_detect 2)"
check "legacy scan reports OTHER with no Copilot author" "OTHER" "$(run_detect 3)"

echo ""
if [ "$fail" -ne 0 ]; then
  echo "Results: ${pass} passed, ${fail} failed" >&2
  exit 1
fi
echo "Results: ${pass} passed, 0 failed"
