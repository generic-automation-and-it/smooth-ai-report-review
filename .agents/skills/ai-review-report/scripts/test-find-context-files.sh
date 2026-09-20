#!/bin/bash
# Offline regression tests for OpenCode v2 context discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINDER="$SCRIPT_DIR/find-context-files.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

fail() { echo "❌ $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "✅ $*"; }

mkdir -p "$REPO/ci_temp" "$REPO/src/feature" "$REPO/.github/instructions/backend" "$REPO/docs"
printf 'src/feature/app.ts\0' > "$REPO/ci_temp/changed_files.txt"
touch "$REPO/AGENTS.md" "$REPO/src/AGENTS.md" "$REPO/src/feature/AGENTS.md"
touch "$REPO/src/FEATURE_AGENTS.md" "$REPO/src/feature/LOCAL_AGENTS.md"
touch "$REPO/docs/AGENTS.md" "$REPO/docs/KEEP_AGENTS.md" "$REPO/docs/rules.txt"
touch "$REPO/.github/instructions/root.instructions.md"
touch "$REPO/.github/instructions/backend/nested.instructions.md"

(
  cd "$REPO"
  GITHUB_OUTPUT="$REPO/output" \
  MANDATORY_CONTEXT_FILES='AGENTS.md docs/AGENTS.md docs/KEEP_AGENTS.md docs/rules.txt' \
    bash "$FINDER" > "$REPO/run.log" 2>&1
)

for expected in \
  src/FEATURE_AGENTS.md \
  src/feature/LOCAL_AGENTS.md \
  docs/KEEP_AGENTS.md \
  docs/rules.txt \
  .github/instructions/root.instructions.md \
  .github/instructions/backend/nested.instructions.md; do
  grep -Fxq "$expected" "$REPO/ci_temp/context_files.txt" \
    || fail "expected context path missing: $expected"
done
ok "custom *_AGENTS.md, mandatory paths, and recursive GitHub rules are retained"

if grep -Eq '(^|/)AGENTS\.md$' "$REPO/ci_temp/context_files.txt"; then
  fail "standard AGENTS.md was duplicated into explicit chunk context"
fi
ok "exact AGENTS.md basenames are excluded for native v2 scope loading"

echo "All $pass find-context-files tests passed"
