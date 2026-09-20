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
# No underscore, on purpose. Every other custom fixture has one, so the suite
# stayed green even if discovery were narrowed back to `*_AGENTS.md` — the
# exact defect fixed twice already. The finder accepts every filename ending
# in AGENTS.md except the exact standard basename; this fixture is what makes
# the test able to tell the difference.
touch "$REPO/src/feature/FooAGENTS.md"
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
  src/feature/FooAGENTS.md \
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

# On v2 nothing resolves the config's `instructions` array, so
# find-context-files.sh is the only thing that loads those files. The docs
# state that as a guarantee ("adding an entry without adding it here ships a
# rule file that silently never reaches the model"), so the test has to check
# the guarantee, not a hardcoded pair: a third tree added to the config must
# fail CI until the finder enumerates it too. Deriving the list from the config
# is the difference between testing the invariant and testing two examples.
CONFIG="$SCRIPT_DIR/../assets/opencode.json"
declared_roots="$(python3 - "$CONFIG" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
roots = []
for entry in cfg.get("instructions", []):
    if "://" in entry:            # URLs are not a filesystem tree
        continue
    head = entry.split("*", 1)[0].rstrip("/")   # prefix before the first glob
    if "/" in head and head not in roots:
        roots.append(head)
print("\n".join(roots))
PYEOF
)"
[ -n "$declared_roots" ] || fail "could not derive any instructions root from $CONFIG"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  grep -Fq "find ${root} -type f" "$FINDER" \
    || fail "opencode.json declares instructions under '${root}/' but find-context-files.sh never enumerates it — on v2 those files would be declared and never loaded"
done <<< "$declared_roots"
ok "every instructions root the config declares is enumerated by the finder ($(echo "$declared_roots" | tr '\n' ' ' | sed 's/ $//'))"

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
