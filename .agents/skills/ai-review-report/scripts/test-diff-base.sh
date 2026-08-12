#!/bin/bash
set -e

# Test script for lib/resolve-diff-base.sh (LADR-075).
#
# The regression under test: when the base branch advances after the PR branch
# point, the old `git fetch --depth=1` + `git merge-base ... || echo
# "$base_sha"` + two-dot-diff pattern silently reviewed every commit the base
# had gained since the branch point, with those commits INVERTED.
#
# The oracle that matters is Test 4: the resolved base must yield EXACTLY the
# files the PR touched. The old code returned two files and said nothing.
#
# No network: all remotes are local file paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=========================================="
echo "Testing resolve-diff-base.sh"
echo "=========================================="
echo ""

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---"; printf '%s\n' "$actual"
    fail=$((fail + 1))
  fi
}

git_q() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# --- Fixture -----------------------------------------------------------------
# base repo:  main: A ──> C (theirs.txt)      ← base advances after branch point
#                    └──> B (mine.txt)  [feature]
BASE_REPO="$TMP_DIR/base"
mkdir -p "$BASE_REPO"
(
  cd "$BASE_REPO"
  git_q init -q .
  git_q commit -q --allow-empty -m A
  git_q checkout -q -b feature
  echo mine > mine.txt && git_q add . && git_q commit -q -m B
  git_q checkout -q main
  echo theirs > theirs.txt && git_q add . && git_q commit -q -m C
)
TRUE_MERGE_BASE="$(cd "$BASE_REPO" && git_q rev-parse main~1)"
BASE_TIP="$(cd "$BASE_REPO" && git_q rev-parse main)"
HEAD_SHA="$(cd "$BASE_REPO" && git_q rev-parse feature)"

# Working checkout, shallowed exactly the way run-review.sh Step 6 shallows it.
WORK="$TMP_DIR/work"
git_q clone -q "$BASE_REPO" "$WORK"
(
  cd "$WORK"
  git_q checkout -q -b feature origin/feature
  git_q remote add upstream "$BASE_REPO"
  git_q fetch -q upstream main --depth=1
)

cd "$WORK"

# Test 1: the fixture genuinely reproduces the shallow graft.
. "$SCRIPT_DIR/lib/resolve-diff-base.sh"
if rdb_is_shallow; then shallow="yes"; else shallow="no"; fi
check "Test 1: --depth=1 shallows a previously complete repo" "yes" "$shallow"

# Test 2: the pre-fix code path really is broken (documents the bug).
# merge-base cannot walk past the graft, so the old `|| echo "$base_sha"`
# fallback fires and the two-dot range picks up the foreign commit.
broken_mb="$(git merge-base "upstream/main" "$HEAD_SHA" 2>/dev/null || echo "$BASE_TIP")"
broken_files="$(git diff --name-only "${broken_mb}..${HEAD_SHA}" | sort | tr '\n' ' ' | sed 's/ $//')"
check "Test 2: old fallback + two-dot pulls in foreign files" "mine.txt theirs.txt" "$broken_files"

# Test 3: resolve_diff_base repairs the graft and returns the TRUE merge-base.
resolved="$(resolve_diff_base main "$HEAD_SHA" 2>/dev/null)"
check "Test 3: resolves the true merge-base, not the base tip" "$TRUE_MERGE_BASE" "$resolved"

# Test 4: THE ORACLE — scope is exactly the PR's own files.
scoped="$(git diff --name-only "${resolved}..${HEAD_SHA}" | sort | tr '\n' ' ' | sed 's/ $//')"
check "Test 4: diff scope is exactly the PR's files" "mine.txt" "$scoped"

# Test 5: the base tip is never returned.
if [ "$resolved" = "$BASE_TIP" ]; then leaked="yes"; else leaked="no"; fi
check "Test 5: base tip is never substituted for the merge-base" "no" "$leaked"

# Test 6: the graft is gone after resolution.
if rdb_is_shallow; then still="yes"; else still="no"; fi
check "Test 6: shallow graft repaired in place" "no" "$still"

# Test 7: memoised — a second call returns the same value without re-fetching.
resolved2="$(resolve_diff_base main "$HEAD_SHA" 2>/dev/null)"
check "Test 7: second call is stable (memoised)" "$TRUE_MERGE_BASE" "$resolved2"

# --- Unrelated-history fixture: resolution must FAIL, loudly ------------------
ALT_REPO="$TMP_DIR/alt"
mkdir -p "$ALT_REPO"
(
  cd "$ALT_REPO"
  git_q init -q .
  git_q commit -q --allow-empty -m unrelated
)
ALT_WORK="$TMP_DIR/altwork"
git_q clone -q "$BASE_REPO" "$ALT_WORK"
(
  cd "$ALT_WORK"
  git_q checkout -q -b feature origin/feature
  git_q remote add upstream "$ALT_REPO"
  git_q fetch -q upstream main
)
cd "$ALT_WORK"

# Fresh shell so the memo cache from the previous fixture cannot answer.
ERR_LOG="$TMP_DIR/err.log"
set +e
bash -c '
  set -euo pipefail
  . "$1/lib/resolve-diff-base.sh"
  resolve_diff_base main "$2"
' _ "$SCRIPT_DIR" "$HEAD_SHA" >"$TMP_DIR/out.log" 2>"$ERR_LOG"
rc=$?
set -e

# Test 8: unresolvable base is a hard failure, not a guess.
check "Test 8: unresolvable merge-base returns non-zero" "1" "$rc"

# Test 9: nothing is printed on stdout — no caller can mistake it for a SHA.
check "Test 9: no SHA emitted on failure" "" "$(cat "$TMP_DIR/out.log")"

# Test 10: the failure is loud (LADR-075 — degrade loudly, never silently).
if grep -q '^::error::' "$ERR_LOG"; then loud="yes"; else loud="no"; fi
check "Test 10: failure emits a ::error:: annotation" "yes" "$loud"

# Test 11: the message tells the operator what to do about it.
if grep -q 'merge or rebase' "$ERR_LOG"; then actionable="yes"; else actionable="no"; fi
check "Test 11: failure message is actionable" "yes" "$actionable"

# Test 12: a three-dot fallback would NOT have been a safe degradation — it
# errors on a shallow repo, and run-review.sh's `2>/dev/null || true` on the
# pr_diff build would have swallowed that into an empty diff. This pins the
# reason resolve_diff_base hard-fails instead of widening the range.
cd "$WORK"
git_q fetch -q upstream main --depth=1 2>/dev/null || true
if git diff --name-only "${BASE_TIP}...${HEAD_SHA}" >/dev/null 2>&1; then
  threedot="ok"
else
  threedot="failed"
fi
check "Test 12: three-dot is not a safe fallback on a shallow repo" "failed" "$threedot"

# --- Structural guards on run-review.sh --------------------------------------
# The bug was a two-line idiom repeated at four sites. Pin its absence rather
# than trusting a reviewer to notice it being pasted back in.
RR="$SCRIPT_DIR/run-review.sh"
# Comment lines are stripped first: the surviving prose deliberately quotes the
# old idiom to explain why it is gone, and must not trip its own guard.
RR_CODE="$TMP_DIR/run-review.code"
grep -v '^[[:space:]]*#' "$RR" > "$RR_CODE"

# Test 13: no site substitutes base_sha for a failed merge-base.
if grep -q 'merge-base.*||[[:space:]]*echo[[:space:]]*"\$base_sha"' "$RR_CODE"; then
  guard="present"
else
  guard="absent"
fi
check "Test 13: no 'merge-base || echo \$base_sha' fallback survives" "absent" "$guard"

# Test 14: the base ref is never shallow-fetched (the head TREE fetch in Step 6
# is the one legitimate --depth=1 and does not name base_ref).
if grep -q 'git fetch upstream "\${base_ref}" --depth=1' "$RR_CODE"; then
  guard="present"
else
  guard="absent"
fi
check "Test 14: base ref is never fetched with --depth=1" "absent" "$guard"

# Test 15: every diff-base resolution goes through the shared helper, and each
# call propagates failure instead of continuing with an empty MERGE_BASE.
calls="$(grep -c 'resolve_diff_base "\${base_ref}" "\${head_sha}")" || exit 1' "$RR_CODE" || true)"
check "Test 15: all 4 sites call resolve_diff_base and exit on failure" "4" "$calls"

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ]
