#!/bin/bash
# L1: the same chunk through both dispatch paths yields byte-identical prompts and
# instruction sets (LADR-130, N2/G2.1). Stub runtimes only — no model call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$3" = "$2" ]; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

setup() { # setup <dir>
  local d="$1"
  mkdir -p "$d/.agents/skills/ai-review-report/scripts/lib" "$d/bin" "$d/ci_temp"
  cp "$SCRIPT_DIR/review-in-chunks.sh" "$d/.agents/skills/ai-review-report/scripts/"
  for lib in count-changed-files.sh extract-findings-json.sh validate-chunk-timeout.sh \
             split-chunk-budget.sh review-has-shape.sh build-runtime-agents.sh; do
    cp "$SCRIPT_DIR/lib/$lib" "$d/.agents/skills/ai-review-report/scripts/lib/"
  done
  cat > "$d/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" <<'STUB'
#!/bin/bash
prompt_file="${@: -1}"
if [[ "$prompt_file" == *semantic_grouping_prompt.txt ]]; then echo "grouping unavailable"; exit 0; fi
printf '### Stub Review\n\n- 🔵 [VERIFIED] Low Priority: stub — `alpha/a.txt:1`.\n\n%.0s' {1..20}
STUB
  chmod +x "$d/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"
  printf '#!/bin/bash\nexec "$@"\n' > "$d/bin/timeout"; chmod +x "$d/bin/timeout"
  ( cd "$d" && git init -q . && git config user.email t@e.com && git config user.name T \
    && mkdir -p alpha && echo one > alpha/a.txt && git add alpha/a.txt && git commit -q -m base \
    && echo two >> alpha/a.txt && git add alpha/a.txt && git commit -q -m head \
    && printf 'alpha/a.txt\0' > ci_temp/changed_files.txt )
}

D="$TMP/repo"
setup "$D"

run_path() { # run_path <backend>
  local backend="$1" d="$D"
  rm -rf "$d/ci_temp/reviews" "$d/ci_temp/chunk_0_prompt.txt" "$d/ci_temp/chunk_0"
  ( cd "$d" \
    && OPENCODE_REVIEW_REPORT_BACKEND="$backend" OPENCODE_REVIEW_REPORT_PROVIDER=OPENAI \
       OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=secondary \
       OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING=1 GITHUB_OUTPUT="$d/gh.out" \
       PATH="$d/bin:$PATH" \
       bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh \
         "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" "primary-model" "test expertise" \
         > "$d/run.log" 2>&1 ) || true
}

echo "=========================================="
echo "Testing backend prompt parity (LADR-130)"
echo "=========================================="

run_path opencode
cp "$D/ci_temp/chunk_0_prompt.txt" "$TMP/oc_prompt.txt"
cp "$D/ci_temp/chunk_0/AGENTS.md" "$TMP/oc_agents.md"
run_path pi

oc_prompt="$TMP/oc_prompt.txt"
pi_prompt="$D/ci_temp/chunk_0_prompt.txt"
check "both dispatch paths produced a chunk prompt" "yes" "$([ -f "$oc_prompt" ] && [ -f "$pi_prompt" ] && echo yes || echo no)"
check "chunk prompt bytes are identical across backends" \
  "$(sha256sum "$oc_prompt" | cut -d' ' -f1)" "$(sha256sum "$pi_prompt" | cut -d' ' -f1)"

oc_agents="$TMP/oc_agents.md"
pi_agents="$D/ci_temp/chunk_0/AGENTS.md"
check "the generated instruction set is present on both paths" "yes" \
  "$([ -f "$oc_agents" ] && [ -f "$pi_agents" ] && echo yes || echo no)"
check "instruction-set hashes match" \
  "$(sha256sum "$oc_agents" | cut -d' ' -f1)" "$(sha256sum "$pi_agents" | cut -d' ' -f1)"

echo ""
echo "=========================================="
if [ "$fail" -eq 0 ]; then echo "All backend prompt-parity tests passed"; else echo "$fail backend prompt-parity test(s) failed"; fi
echo "=========================================="
[ "$fail" -eq 0 ]
