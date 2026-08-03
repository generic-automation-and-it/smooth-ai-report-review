#!/bin/bash
set -euo pipefail

# Test script for the silent-pass verification lens (LADR-060).
#
# test-chunk-prompt-guards.sh asserts statically that the is_verification branch
# precedes is_doc_only in source order. That is necessary but not sufficient: the
# detection matches PATH PREFIXES (`.github/workflows/*`), and every path in the
# chunk file list used to arrive with a stray leading `:` from the grouping
# split, against which no prefix glob can ever match. A correctly ordered branch
# that never fires looks exactly like a correctly ordered branch that does.
#
# So this suite runs the real review-in-chunks.sh over sandbox repos and asserts
# on the prompt it actually produced.

echo "=========================================="
echo "Testing verification-mechanism lens (LADR-060)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0
ok()  { echo "✅ $1"; pass=$((pass + 1)); }
bad() { echo "❌ $1"; fail=$((fail + 1)); }

# Build a sandbox repo whose single changed file is $1, run the chunk script,
# and echo the generated prompt path.
run_chunk_for() {
  local changed_path="$1" label="$2"
  local repo="$TMP_DIR/$label"
  mkdir -p "$repo/.agents/skills/ai-review-report/scripts/lib" "$repo/bin"
  cp "$SCRIPT_DIR/review-in-chunks.sh" "$repo/.agents/skills/ai-review-report/scripts/"
  local lib
  for lib in count-changed-files.sh extract-findings-json.sh validate-chunk-timeout.sh build-blame-digest.sh; do
    cp "$SCRIPT_DIR/lib/$lib" "$repo/.agents/skills/ai-review-report/scripts/lib/"
  done
  cat > "$repo/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" <<'STUB'
#!/bin/bash
prompt_file="${@: -1}"
if [[ "$prompt_file" == *"semantic_grouping_prompt.txt" ]]; then
  echo "semantic grouping unavailable in test"
else
  printf '### Test Review\n\n- 🔵 [VERIFIED] Low Priority: none.\n\n%.0s' {1..20}
fi
STUB
  chmod +x "$repo/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"
  printf '#!/bin/bash\nshift\nexec "$@"\n' > "$repo/bin/timeout"
  chmod +x "$repo/bin/timeout"

  (
    cd "$repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    mkdir -p "$(dirname "$changed_path")"
    printf 'name: base\non: push\n' > "$changed_path"
    git add -A
    git commit -qm "base"
    printf 'name: base\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n' > "$changed_path"
    git commit -qam "change the mechanism"
    mkdir -p ci_temp
    printf '%s\0' "$changed_path" > ci_temp/changed_files.txt
    PATH="$repo/bin:$PATH" bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh \
      "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" "test-model" "test expertise" \
      > "$repo/run.log" 2>&1
  ) || true

  ls "$repo"/ci_temp/chunk_*_prompt.txt 2>/dev/null | head -n1
}

# Case 1: a workflow-only chunk. `*.yml` is in the doc-only allowlist, so before
# LADR-060 this chunk was routed to the DOCUMENTATION prompt — the one that opens
# with "Documentation PRs have inherently lower risk" and caps drift findings at
# 🟡 Medium (LADR-046). For a file whose whole job is to decide whether other
# code is allowed to merge, that is the wrong lens.
wf_prompt="$(run_chunk_for ".github/workflows/gate.yml" "workflow")"
if [ -n "$wf_prompt" ] && grep -q "VERIFICATION MECHANISM CHUNK" "$wf_prompt"; then
  ok "workflow-only chunk gets the verification lens"
else
  bad "workflow-only chunk did NOT get the verification lens"
  echo "    prompt: ${wf_prompt:-<none generated>}"
fi

if [ -n "$wf_prompt" ] && ! grep -q "REVIEW INSTRUCTIONS (DOCUMENTATION CHUNK)" "$wf_prompt"; then
  ok "workflow-only chunk is not also routed to the documentation prompt"
else
  bad "workflow-only chunk still received the documentation prompt"
fi

# The lens must not silently inherit the documentation drift cap.
if [ -n "$wf_prompt" ] && grep -q "LADR-046 documentation drift cap does NOT apply here" "$wf_prompt"; then
  ok "verification prompt states the LADR-046 cap does not apply"
else
  bad "verification prompt does not reconcile with the LADR-046 drift cap"
fi

# Case 2: an ordinary markdown-only chunk must still get the documentation lens.
# A verification branch that fires on everything is as wrong as one that never
# fires, and is much harder to notice.
doc_prompt="$(run_chunk_for "docs/notes.md" "docs")"
if [ -n "$doc_prompt" ] && grep -q "REVIEW INSTRUCTIONS (DOCUMENTATION CHUNK)" "$doc_prompt"; then
  ok "markdown-only chunk still gets the documentation lens"
else
  bad "markdown-only chunk lost the documentation lens"
  echo "    prompt: ${doc_prompt:-<none generated>}"
fi

if [ -n "$doc_prompt" ] && ! grep -q "VERIFICATION MECHANISM CHUNK" "$doc_prompt"; then
  ok "verification lens does not fire on ordinary documentation"
else
  bad "verification lens over-fired on a documentation chunk"
fi

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Verification lens tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Verification lens tests passed ($pass checks)"
echo "=========================================="
