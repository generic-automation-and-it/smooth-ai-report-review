#!/bin/bash
# L1: the real dispatcher delivers byte-identical prompts and instruction sets on
# both backends (LADR-130, N2/G2.1). Stub runtime executables only — no model call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

D="$TMP/repo"
mkdir -p "$D/.agents/skills/ai-review-report/scripts/lib" "$D/bin" "$D/ci_temp"
D="$(cd "$D" && pwd -P)"
cp "$SCRIPT_DIR/review-in-chunks.sh" "$D/.agents/skills/ai-review-report/scripts/"
for lib in count-changed-files.sh extract-findings-json.sh validate-chunk-timeout.sh \
           split-chunk-budget.sh review-has-shape.sh build-runtime-agents.sh \
           opencode-with-fallback.sh backend-selector.sh backend-probe.sh prepare-pi-config.sh \
           report-error-log.sh; do
  cp "$SCRIPT_DIR/lib/$lib" "$D/.agents/skills/ai-review-report/scripts/lib/"
done
mkdir -p "$D/.agents/skills/ai-review-report/assets/pi"
cp "$REPO_ROOT/.agents/skills/ai-review-report/assets/role-contract.json" "$D/.agents/skills/ai-review-report/assets/role-contract.json"
cp "$REPO_ROOT/.agents/skills/ai-review-report/assets/pi/policy.js" "$D/.agents/skills/ai-review-report/assets/pi/policy.js"

# Stub runtime executables: the REAL dispatcher selects and invokes them.
cat > "$D/bin/opencode" <<OC
#!/bin/bash
cat > "$D/oc.stdin"
_root="\$(git -C "\$PWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "\$PWD")"
_root="\$(cd "\$_root" 2>/dev/null && pwd -P)"
: > "$D/oc.ctx"
[ -f "\$_root/AGENTS.md" ] && cat "\$_root/AGENTS.md" >> "$D/oc.ctx"
_rel="\$(pwd -P)"
while [ "\$_rel" != "\$_root" ]; do
  [ -f "\$_rel/AGENTS.md" ] && cat "\$_rel/AGENTS.md" >> "$D/oc.ctx"
  _rel="\$(dirname "\$_rel")"
done
printf '### Stub Review\\n\\n- 🔵 [VERIFIED] Low Priority: stub — \`alpha/a.txt:1\`.\\n\\n%.0s' {1..20}
OC
chmod +x "$D/bin/opencode"
cat > "$D/bin/pi" <<PI
#!/bin/bash
_prev=""
for _a in "\$@"; do
  [ "\$_prev" = "--append-system-prompt" ] && cp "\$_a" "$D/pi.ctx"
  _prev="\$_a"
done
cat > "$D/pi.stdin"
printf '### Stub Review\\n\\n- 🔵 [VERIFIED] Low Priority: stub — \`alpha/a.txt:1\`.\\n\\n%.0s' {1..20}
PI
chmod +x "$D/bin/pi"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$D/bin/timeout"; chmod +x "$D/bin/timeout"

cat > "$D/opencode.json" <<'JSON'
{"provider":{"openai":{"npm":"@ai-sdk/openai","options":{"apiKey":"{env:OPENCODE_OPENAI_API_KEY}"},"models":{"m":{}}}}}
JSON

mkdir -p "$D/agent"
( cd "$D" && git init -q . && git config user.email t@e.com && git config user.name T \
  && mkdir -p alpha ci_temp && printf 'ROOT-CTX-MARKER\n' > AGENTS.md \
  && printf 'NESTED-CTX-MARKER\n' > ci_temp/AGENTS.md \
  && echo one > alpha/a.txt && git add -A && git commit -q -m base \
  && echo two >> alpha/a.txt && git add alpha/a.txt && git commit -q -m head \
  && printf 'alpha/a.txt\0' > ci_temp/changed_files.txt )

run_path() { # run_path <backend>
  local backend="$1"
  rm -rf "$D/ci_temp/reviews" "$D/ci_temp/chunk_0_prompt.txt" "$D/ci_temp/chunk_0" \
         "$D/oc.stdin" "$D/oc.ctx" "$D/pi.stdin" "$D/pi.ctx"
  ( cd "$D" \
    && OPENCODE_REVIEW_REPORT_BACKEND="$backend" OPENCODE_REVIEW_REPORT_PROVIDER=OPENAI \
       OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=secondary \
       OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING=1 GITHUB_OUTPUT="$D/gh.out" \
       OPENCODE_CONFIG="$D/opencode.json" OPENCODE_OPENAI_API_KEY=local-dummy \
       PI_CODING_AGENT_DIR="$D/agent" PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 \
       PATH="$D/bin:$PATH" \
       bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh \
         "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" "primary-model" "test expertise" \
         > "$D/run-$backend.log" 2>&1 ) || true
}

echo "=========================================="
echo "Testing backend prompt parity (LADR-130)"
echo "=========================================="

run_path opencode
cp "$D/ci_temp/chunk_0_prompt.txt" "$TMP/oc_prompt.txt"
cp "$D/ci_temp/chunk_0/AGENTS.md" "$TMP/oc_agents.md"
cp "$D/oc.stdin" "$TMP/oc_stdin"
cp "$D/oc.ctx" "$TMP/oc_ctx"
oc_stdin="$TMP/oc_stdin"
run_path pi
pi_stdin="$D/pi.stdin"

check "the opencode stub runtime was dispatched" "yes" "$([ -s "$oc_stdin" ] && echo yes || echo no)"
check "the pi stub runtime was dispatched" "yes" "$([ -s "$pi_stdin" ] && echo yes || echo no)"
check "runtime stdin bytes are identical across backends" \
  "$(sha256sum "$oc_stdin" | cut -d' ' -f1)" "$(sha256sum "$pi_stdin" | cut -d' ' -f1)"
check "each runtime received the generated prompt file" \
  "$(sha256sum "$TMP/oc_prompt.txt" | cut -d' ' -f1)" "$(sha256sum "$pi_stdin" | cut -d' ' -f1)"
check "the generated instruction set is identical across backends" \
  "$(sha256sum "$TMP/oc_agents.md" | cut -d' ' -f1)" "$(sha256sum "$D/ci_temp/chunk_0/AGENTS.md" | cut -d' ' -f1)"
check "the complete delivered context is identical across backends (line set)" \
  "$(grep -v '^$' "$TMP/oc_ctx" 2>/dev/null | sort | sha256sum | cut -d' ' -f1)" \
  "$(grep -v '^$' "$D/pi.ctx" 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
check "pi receives the root context marker" "1" "$(grep -c 'ROOT-CTX-MARKER' "$D/pi.ctx" 2>/dev/null || true)"
_gen_line="$(awk 'NF { print; exit }' "$D/ci_temp/chunk_0/AGENTS.md" 2>/dev/null)"
check "pi receives the generated chunk instructions" "1" \
  "$(grep -cF -- "$_gen_line" "$D/pi.ctx" 2>/dev/null || true)"
check "the opencode path still produced a shape-valid review" "0" \
  "$(bash "$SCRIPT_DIR/lib/review-has-shape.sh" "$D/ci_temp/reviews/chunk_0.md" >/dev/null 2>&1; echo $?)"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All backend prompt-parity tests passed"; else echo "$fail backend prompt-parity test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
