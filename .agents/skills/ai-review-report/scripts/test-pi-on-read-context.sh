#!/bin/bash
# L0/L1: the on-read extension attaches a nested AGENTS.md exactly once and
# never overrides a delivered start-set file (LADR-132).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
EXT="$REPO_ROOT/.agents/skills/ai-review-report/assets/pi/on-read-context.js"

command -v node >/dev/null 2>&1 || { echo "❌ node is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
mkdir -p "$WS/sub" "$WS/sub2" "$WS/other"
printf 'ROOT-CTX\n' > "$WS/AGENTS.md"
printf 'SUB-CTX\n' > "$WS/sub/AGENTS.md"
printf 'file\n' > "$WS/sub/file.txt"
printf 'file\n' > "$WS/sub2/file.txt"
printf 'file\n' > "$WS/rootfile.txt"
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

cat > "$TMP/harness.mjs" <<'H'
const mod = await import("file://" + process.argv[2]);
const hs = [];
mod.default({ on: (n, f) => hs.push(f) });
const handler = hs[0];
const cases = JSON.parse(process.argv[3]);
const out = [];
for (const c of cases) {
  const ev = { toolName: c.tool, input: { path: c.path }, content: [{ type: "text", text: "FILE" }], isError: !!c.error };
  const r = await handler(ev);
  const texts = r && r.content ? r.content.map((p) => p.text || "").join("\n") : "";
  out.push({ id: c.id, appended: texts.includes(c.marker || "CTX"), count: (texts.match(new RegExp(c.marker || "CTX", "g")) || []).length, changed: !!r });
}
process.stdout.write(JSON.stringify(out));
H

run() { # run <json>
  PI_WORKSPACE_ROOT="$WS" PI_CONTEXT_DELIVERED_DIRS="$WS" node "$TMP/harness.mjs" "$EXT" "$1"
}
get() { node -e 'const a=JSON.parse(process.argv[1]);const r=a.find(x=>x.id===process.argv[2]);process.stdout.write(String(r?r[process.argv[3]]:"missing"))' "$1" "$2" "$3"; }

echo "=========================================="
echo "Testing pi on-read context extension (LADR-132)"
echo "=========================================="

out="$(run '[{"id":"nested","tool":"read","path":"sub/file.txt","marker":"SUB-CTX"},{"id":"again","tool":"read","path":"sub/file.txt","marker":"SUB-CTX"},{"id":"root-delivered","tool":"read","path":"rootfile.txt","marker":"ROOT-CTX"},{"id":"no-context","tool":"read","path":"sub2/file.txt","marker":"SUB-CTX"},{"id":"outside","tool":"read","path":"../outside.txt","marker":"CTX"},{"id":"errored","tool":"read","path":"sub/file.txt","marker":"SUB-CTX","error":true},{"id":"other-tool","tool":"find","path":"sub","marker":"CTX"}]')"

check "a nested AGENTS.md is attached on read" "true" "$(get "$out" nested appended)"
check "the attachment is not duplicated on a repeat read" "false" "$(get "$out" again appended)"
check "a start-set directory is never re-attached" "false" "$(get "$out" root-delivered appended)"
check "a directory without AGENTS.md adds nothing" "false" "$(get "$out" no-context appended)"
check "a path outside the workspace adds nothing" "false" "$(get "$out" outside appended)"
check "an errored read adds nothing" "false" "$(get "$out" errored appended)"
check "a non-read tool adds nothing" "false" "$(get "$out" other-tool appended)"

# The byte cap holds: a large nested file is truncated, not dropped.
python3 - "$WS/sub/AGENTS.md" <<'PY'
import sys
open(sys.argv[1],'w').write("X" * (64 * 1024) + "\n")
PY
out="$(run '[{"id":"capped","tool":"read","path":"sub/file.txt","marker":"X"}]')"
check "a large nested file is still attached (capped)" "true" "$(get "$out" capped appended)"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All pi on-read context tests passed"; else echo "$fail pi on-read context test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
