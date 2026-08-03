#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "Testing build-blame-digest.sh (LADR-061)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLAME_DIGEST="$SCRIPT_DIR/lib/build-blame-digest.sh"

pass=0
fail=0

ok()   { echo "✅ $1"; pass=$((pass + 1)); }
bad()  { echo "❌ $1"; fail=$((fail + 1)); }

[ -x "$BLAME_DIGEST" ] || { echo "❌ $BLAME_DIGEST not executable or missing"; exit 1; }

# Build a fixture repo with two commits so we can test blame provenance.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$TMP_DIR"
git init
git config user.email "test@test.com"
git config user.name "Test User"

# Commit 1: initial file
echo "line1" > file.txt
git add file.txt
git commit -m "Initial commit" --quiet
COMMIT1="$(git rev-parse HEAD)"

# Commit 2: modify the file (this is the "diff" we're reviewing)
echo "line2" >> file.txt
git add file.txt
git commit -m "Add line2" --quiet
COMMIT2="$(git rev-parse HEAD)"

# Write the changed file list (NUL-delimited)
printf 'file.txt\0' > "$TMP_DIR/changed_files.txt"

# Run the blame digest. HEAD_SHA=COMMIT2 (the tip), FROM_SHA=COMMIT1 (the base).
export HEAD_SHA="$COMMIT2"
export FROM_SHA="$COMMIT1"

digest="$(printf 'file.txt\0' | timeout 10s bash "$BLAME_DIGEST" 2>/dev/null || true)"

# Test 1: digest is non-empty when there are changed lines.
if [ -n "$digest" ]; then
  ok "blame digest is non-empty for changed file"
else
  bad "blame digest is empty for changed file"
fi

# Test 2: digest contains the commit SHA of the change.
if echo "$digest" | grep -q "$(echo "$COMMIT2" | cut -c1-7)"; then
  ok "blame digest contains the commit SHA"
else
  bad "blame digest does not contain the commit SHA"
  echo "    digest: $digest"
fi

# Test 3: digest is deduplicated — each commit appears at most once.
# `grep -c || echo 0` emits "0\n0" when grep matches nothing (grep prints its
# own 0, then the || arm fires), which makes the following [ ] a syntax error
# rather than a failed assertion. Count without the fallback.
dupes="$(printf '%s\n' "$digest" | grep '|' | awk '{print $1}' | sort | uniq -d)"
if [ -z "$dupes" ]; then
  ok "blame digest is deduplicated (one row per commit)"
else
  bad "blame digest has duplicate commit rows"
  echo "    duplicated: $dupes"
fi

# Test 4: digest does not contain full-file blame (no per-line rows).
# Each line should be "sha author date subject | file", not individual line numbers.
if echo "$digest" | grep -qE '^[0-9a-f]{7,40} '; then
  ok "blame digest uses commit-level format (not per-line)"
else
  bad "blame digest does not use expected commit-level format"
fi

# Test 5: graceful degradation when HEAD_SHA is missing.
unset HEAD_SHA
digest2="$(printf 'file.txt\0' | timeout 10s bash "$BLAME_DIGEST" 2>/dev/null || true)"
if [ -z "$digest2" ]; then
  ok "blame digest is empty when HEAD_SHA is unset (graceful degradation)"
else
  bad "blame digest should be empty when HEAD_SHA is unset"
fi

# Test 6: graceful degradation when FROM_SHA is missing.
export HEAD_SHA="$COMMIT2"
unset FROM_SHA
digest3="$(printf 'file.txt\0' | timeout 10s bash "$BLAME_DIGEST" 2>/dev/null || true)"
if [ -z "$digest3" ]; then
  ok "blame digest is empty when FROM_SHA is unset (graceful degradation)"
else
  bad "blame digest should be empty when FROM_SHA is unset"
fi

# Test 7: a diff with TWO separated hunks must report BOTH contributing
# commits. This is the regression test for the original defect class: the
# ranges were joined into a single `-L "a,b c,d"` argument (git accepts only one
# range per -L, so blame failed outright) and the SHAs were matched as 40-char
# strings against abbreviated, non-porcelain blame output (so nothing matched
# even when blame succeeded). Both bugs produce an empty digest, which the
# single-hunk fixture above cannot distinguish from "blame found one commit".
export HEAD_SHA FROM_SHA
seq 1 60 > wide.txt
git add wide.txt
git commit -qm "wide baseline"
WIDE_BASE="$(git rev-parse HEAD)"

sed -i '5s/.*/EARLY EDIT/' wide.txt
git commit -qam "edit near the top"
EARLY="$(git rev-parse HEAD)"

sed -i '55s/.*/LATE EDIT/' wide.txt
git commit -qam "edit near the bottom"
LATE="$(git rev-parse HEAD)"

export HEAD_SHA="$LATE"
export FROM_SHA="$WIDE_BASE"
digest4="$(printf 'wide.txt\0' | timeout 10s bash "$BLAME_DIGEST" 2>/dev/null || true)"

early_short="$(git rev-parse --short "$EARLY")"
late_short="$(git rev-parse --short "$LATE")"
if printf '%s' "$digest4" | grep -q "$early_short" && printf '%s' "$digest4" | grep -q "$late_short"; then
  ok "both hunks' commits are reported (multi-range -L + porcelain SHA extraction)"
else
  bad "multi-hunk digest is missing a contributing commit"
  echo "    expected $early_short and $late_short"
  echo "    digest: $digest4"
fi

# Test 8: the digest names the file each commit touched.
if printf '%s' "$digest4" | grep -q '| wide.txt'; then
  ok "digest rows carry the file list"
else
  bad "digest rows do not carry the file list"
fi

# Test 9: a path that does not exist at HEAD is skipped, not fatal.
digest5="$(printf 'no-such-file.txt\0' | timeout 10s bash "$BLAME_DIGEST" 2>/dev/null; echo "exit=$?")"
if printf '%s' "$digest5" | grep -q 'exit=0'; then
  ok "missing path degrades gracefully (exit 0, no output)"
else
  bad "missing path did not degrade gracefully: $digest5"
fi

# ── Integration: the digest must actually reach a chunk prompt ──────────────
# Every static check in test-chunk-prompt-guards.sh passed against the first
# implementation, which was nonetheless dead in two independent ways ($LIB_DIR
# unset in review-in-chunks.sh, and the head SHA named $HEAD_SHA there instead
# of $TO_SHA). Only running the real script catches that class, so this case
# builds a sandbox repo, runs review-in-chunks.sh with a stubbed model, and
# asserts the provenance block landed in the generated prompt.
INT_DIR="$TMP_DIR/integration"
SKILL_SCRIPTS="$SCRIPT_DIR"
mkdir -p "$INT_DIR/repo/.agents/skills/ai-review-report/scripts/lib" "$INT_DIR/repo/bin"
cp "$SKILL_SCRIPTS/review-in-chunks.sh" "$INT_DIR/repo/.agents/skills/ai-review-report/scripts/"
for lib in count-changed-files.sh extract-findings-json.sh validate-chunk-timeout.sh build-blame-digest.sh; do
  cp "$SKILL_SCRIPTS/lib/$lib" "$INT_DIR/repo/.agents/skills/ai-review-report/scripts/lib/"
done
cat > "$INT_DIR/repo/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" <<'STUB'
#!/bin/bash
prompt_file="${@: -1}"
if [[ "$prompt_file" == *"semantic_grouping_prompt.txt" ]]; then
  echo "semantic grouping unavailable in test"
else
  printf '### Test Review\n\n- 🔵 [VERIFIED] Low Priority: none.\n\n%.0s' {1..20}
fi
STUB
chmod +x "$INT_DIR/repo/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"
cat > "$INT_DIR/repo/bin/timeout" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
chmod +x "$INT_DIR/repo/bin/timeout"

(
  cd "$INT_DIR/repo"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test User"
  mkdir -p src
  printf 'alpha\nbravo\ncharlie\n' > src/app.txt
  git add -A
  git commit -qm "base"
  printf 'alpha\nBRAVO CHANGED\ncharlie\n' > src/app.txt
  git commit -qam "change bravo"
  mkdir -p ci_temp
  printf 'src/app.txt\0' > ci_temp/changed_files.txt
  PATH="$INT_DIR/repo/bin:$PATH" bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh \
    "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" "test-model" "test expertise" \
    > "$INT_DIR/run.log" 2>&1
) || true

int_prompt="$(ls "$INT_DIR"/repo/ci_temp/chunk_*_prompt.txt 2>/dev/null | head -n1)"
if [ -n "$int_prompt" ] && grep -q "Git Blame Provenance" "$int_prompt"; then
  ok "provenance block reaches a real chunk prompt (wiring is live)"
else
  bad "provenance block missing from the generated chunk prompt"
  echo "    prompt: ${int_prompt:-<none generated>}"
  tail -5 "$INT_DIR/run.log" 2>/dev/null | sed 's/^/    /'
fi

if [ -n "$int_prompt" ] && grep -q "change bravo" "$int_prompt"; then
  ok "the inlined digest names the commit that touched the changed line"
else
  bad "the inlined digest does not name the contributing commit"
fi

# The side-file must exist alongside the inlined extract.
if ls "$INT_DIR"/repo/ci_temp/chunk_*_blame.md >/dev/null 2>&1; then
  ok "per-chunk blame side-file is written"
else
  bad "per-chunk blame side-file is missing"
fi

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Blame digest tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Blame digest tests passed ($pass checks)"
echo "=========================================="