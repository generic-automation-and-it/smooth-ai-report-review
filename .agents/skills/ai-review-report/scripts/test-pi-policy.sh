#!/bin/bash
# L0/L1: policy.js enforces the role contract on every pi tool call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
POLICY="$REPO_ROOT/.agents/skills/ai-review-report/assets/pi/policy.js"

command -v node >/dev/null 2>&1 || { echo "❌ node is required for test-pi-policy.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/ws"
mkdir -p "$ROOT/sub/.git" "$ROOT/.git" "$ROOT/.context" "$ROOT/.smooth-ai-review-tools" "$ROOT/.smooth-ai-review-tools" "$ROOT/.context" "$ROOT/ci_temp"
printf 'x\n' > "$ROOT/src.js"; printf 'x\n' > "$ROOT/.env"; printf 'x\n' > "$ROOT/.env.production"
printf 'SAFE=1\n' > "$ROOT/.env.example"; printf 'x\n' > "$ROOT/.git/config"
rm -f "$ROOT/.env.example"; ln -s .env "$ROOT/.env.example"
printf 'x\n' > "$ROOT/sub/.git/config"; printf 'safe\n' > "$ROOT/safe.txt"; printf 'SAFE=1\n' > "$ROOT/sub/.env.example"; ln -s ../safe.txt "$ROOT/sub/.env"
printf 'x\n' > "$ROOT/.context/.env.example"
printf 'x\n' > "$ROOT/.smooth-ai-review-tools/.env.example"
ln -s "$ROOT/src.js" "$ROOT/link-in.js"; ln -s /etc/hosts "$ROOT/link-out.js"
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

cat > "$TMP/harness.mjs" <<'HARNESS'
import path from "node:path";
const policyPath = process.argv[2];
const root = process.argv[3];
const mod = await import("file://" + policyPath);
const handlers = [];
const pi = { on: (name, fn) => handlers.push(fn) };
mod.default(pi);
const handler = handlers[0];
const cases = JSON.parse(process.argv[4]);
const out = [];
for (const c of cases) {
  const r = await handler({ toolName: c.tool, input: c.input || {} });
  out.push({ id: c.id, result: r && r.block ? "block" : "allow" });
}
process.stdout.write(JSON.stringify(out));
HARNESS

run_cases() { # run_cases <role|""> <root|""> <json>
  PI_ROLE="$1" PI_WORKSPACE_ROOT="$2" node "$TMP/harness.mjs" "$POLICY" "$ROOT" "$3"
}

CASES_REVIEW='[
 {"id":"read-allowed","tool":"read","input":{"path":"src.js"}},
 {"id":"find-allowed","tool":"find","input":{"pattern":"x","path":"."}},
 {"id":"ls-allowed","tool":"ls","input":{}},
 {"id":"edit-blocked","tool":"edit","input":{"path":"src.js"}},
 {"id":"write-blocked","tool":"write","input":{"path":"src.js"}},
 {"id":"bash-blocked","tool":"bash","input":{}},
 {"id":"codemode-blocked","tool":"codemode","input":{}},
 {"id":"toolsearch-blocked","tool":"tool_search","input":{}},
 {"id":"mcp-blocked","tool":"mcp__x__y","input":{}},
 {"id":"unknown-blocked","tool":"frobnicate","input":{}},
 {"id":"env-blocked","tool":"read","input":{"path":".env"}},
 {"id":"env-prod-blocked","tool":"read","input":{"path":".env.production"}},
 {"id":"env-example-symlink-blocked","tool":"read","input":{"path":".env.example"}},
 {"id":"env-example-allowed","tool":"read","input":{"path":"sub/.env.example"}},
 {"id":"git-config-blocked","tool":"read","input":{"path":".git/config"}},
 {"id":"nested-git-blocked","tool":"read","input":{"path":"sub/.git/config"}},
 {"id":"nested-env-blocked","tool":"read","input":{"path":"sub/.env"}},
 {"id":"git-env-example-blocked","tool":"read","input":{"path":".git/.env.example"}},
 {"id":"proc-blocked","tool":"read","input":{"path":"/proc/self/environ"}},
 {"id":"home-blocked","tool":"read","input":{"path":"~/.npmrc"}},
 {"id":"outside-blocked","tool":"read","input":{"path":"../outside"}},
 {"id":"symlink-in-allowed","tool":"read","input":{"path":"link-in.js"}},
 {"id":"symlink-out-blocked","tool":"read","input":{"path":"link-out.js"}},
 {"id":"grep-blocked","tool":"grep","input":{"pattern":"x","path":"src.js"}},
 {"id":"grep-pathless-blocked","tool":"grep","input":{"pattern":"x"}}
]'

out="$(run_cases review "$ROOT" "$CASES_REVIEW")"
check "the protected-name symlink fixture exists" "yes" "$([ -L "$ROOT/.env.example" ] && [ -L "$ROOT/sub/.env" ] && echo yes || echo no)"

echo "=========================================="
echo "Testing pi policy extension (LADR-127)"
echo "=========================================="
check_result() { # check_result <id> <expected>
  check "$1 $2" "$2" "$(node -e 'const a=JSON.parse(process.argv[1]);const r=a.find(x=>x.id===process.argv[2]);process.stdout.write(r?r.result:"missing")' "$out" "$1")"
}
for id in read-allowed find-allowed ls-allowed env-example-allowed symlink-in-allowed; do check_result "$id" allow; done
for id in edit-blocked write-blocked bash-blocked codemode-blocked toolsearch-blocked mcp-blocked unknown-blocked env-blocked env-prod-blocked git-config-blocked nested-git-blocked nested-env-blocked git-env-example-blocked proc-blocked home-blocked outside-blocked symlink-out-blocked grep-blocked grep-pathless-blocked; do check_result "$id" block; done

CASES_ANALYSE='[
 {"id":"edit-allowed","tool":"edit","input":{"path":"src.js"}},
 {"id":"write-blocked","tool":"write","input":{"path":"src.js"}},
 {"id":"bash-blocked","tool":"bash","input":{}},
 {"id":"mcp-blocked","tool":"mcp__x","input":{}},
 {"id":"tooling-blocked","tool":"edit","input":{"path":".smooth-ai-review-tools/x.sh"}},
 {"id":"context-blocked","tool":"edit","input":{"path":".context/x.json"}},
 {"id":"temp-blocked","tool":"edit","input":{"path":"ci_temp/x.txt"}},
 {"id":"git-blocked","tool":"edit","input":{"path":".git/config"}},
 {"id":"env-blocked","tool":"edit","input":{"path":".env"}},
 {"id":"env-example-allowed","tool":"edit","input":{"path":"sub/.env.example"}},
 {"id":"context-env-example-blocked","tool":"edit","input":{"path":".context/.env.example"}},
 {"id":"tooling-env-example-blocked","tool":"edit","input":{"path":".smooth-ai-review-tools/.env.example"}},
 {"id":"read-env-blocked","tool":"read","input":{"path":".env"}},
 {"id":"new-file-allowed","tool":"edit","input":{"path":"sub/new.js"}},
 {"id":"grep-blocked","tool":"grep","input":{"pattern":"x","path":"src.js"}}
]'
out="$(run_cases analyse "$ROOT" "$CASES_ANALYSE")"
for id in edit-allowed env-example-allowed new-file-allowed; do check_result "$id" allow; done
for id in write-blocked bash-blocked mcp-blocked tooling-blocked context-blocked temp-blocked git-blocked env-blocked read-env-blocked grep-blocked context-env-example-blocked tooling-env-example-blocked; do check_result "$id" block; done

# Fail closed on missing inputs.
out="$(run_cases "" "$ROOT" '[{"id":"no-role","tool":"read","input":{"path":"src.js"}}]')"
check_result no-role block
out="$(run_cases review "" '[{"id":"no-root","tool":"read","input":{"path":"src.js"}}]')"
check_result no-root block

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All pi-policy tests passed"; else echo "$fail pi-policy test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
