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

mkdir -p "$REPO/ci_temp" "$REPO/src/feature" "$REPO/.github/instructions/backend" "$REPO/docs" \
  "$REPO/.agents/rules/backend" "$REPO/.agents/rules-scoped/backend"
printf 'src/feature/app.ts\0' > "$REPO/ci_temp/changed_files.txt"
touch "$REPO/AGENTS.md" "$REPO/src/AGENTS.md" "$REPO/src/feature/AGENTS.md"
touch "$REPO/src/FEATURE_AGENTS.md" "$REPO/src/feature/LOCAL_AGENTS.md"
touch "$REPO/docs/AGENTS.md" "$REPO/docs/KEEP_AGENTS.md" "$REPO/docs/rules.txt"
touch "$REPO/.github/instructions/root.instructions.md"
touch "$REPO/.github/instructions/backend/nested.instructions.md"
touch "$REPO/.agents/rules/top.md" "$REPO/.agents/rules/backend/nested.md"
touch "$REPO/.agents/rules-scoped/backend/testing-standards.instructions.md"

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
  .github/instructions/backend/nested.instructions.md \
  .agents/rules/top.md \
  .agents/rules/backend/nested.md; do
  grep -Fxq "$expected" "$REPO/ci_temp/context_files.txt" \
    || fail "expected context path missing: $expected"
done
ok "custom *AGENTS.md, mandatory paths, and recursive .agents + GitHub rules are retained"

if grep -Eq '(^|/)AGENTS\.md$' "$REPO/ci_temp/context_files.txt"; then
  fail "standard AGENTS.md was duplicated into explicit chunk context"
fi
ok "exact AGENTS.md basenames are excluded for native v2 scope loading"

# The config declares `.agents/rules/*.md` AND `.agents/rules/**/*.md`; on v2
# neither is resolved, so this finder is the only thing that loads them. Both
# glob forms are one recursive `find` here — the pair exists in the config
# because v1's glob engine distinguished them, not because they name different
# files. A config entry with no counterpart here is declared-but-never-loaded.
CONFIG="$SCRIPT_DIR/../assets/opencode.json"
for declared in '.agents/rules' '.github/instructions'; do
  grep -Fq "\"${declared}/" "$CONFIG" \
    || fail "config no longer declares ${declared}/ in instructions — update this test with it"
  grep -Fq "find ${declared} -type f" "$FINDER" \
    || fail "config declares ${declared}/ but find-context-files.sh never enumerates it"
done
ok "every instructions default the config declares is also loaded explicitly"

# Scoped rules are excluded on purpose: they reach a review through
# MANDATORY_CONTEXT_FILES, which the consuming repo controls per-run. Pulling
# the whole tree into every chunk would duplicate them and inflate prompts for
# chunks the scope does not cover.
if grep -q 'rules-scoped' "$REPO/ci_temp/context_files.txt"; then
  fail "the scoped rules tree was pulled into explicit context"
fi
if grep -Fq 'rules-scoped' "$CONFIG"; then
  fail "the config re-declared .agents/rules-scoped in instructions"
fi
ok ".agents/rules-scoped stays out of both the config and the explicit context"

echo "All $pass find-context-files tests passed"
