#!/usr/bin/env bash
# Test script for lib/select-ai-analyse-artifact.sh
# Verifies the unified descending timeline of PR reviews + issue comments that
# drives the ai-analyse guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/lib/select-ai-analyse-artifact.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_GH="$TMP_DIR/gh"
cat > "$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
# Fake gh for testing. Expects GH_FIXTURE_REVIEWS and GH_FIXTURE_COMMENTS env
# vars pointing to JSON files (single arrays or multiple arrays for --paginate).
args=("$@")
endpoint="${args[-1]}"
if [[ "$endpoint" == *"/pulls/"*"/reviews" ]]; then
  cat "${GH_FIXTURE_REVIEWS:-/dev/null}"
elif [[ "$endpoint" == *"/issues/"*"/comments" ]]; then
  cat "${GH_FIXTURE_COMMENTS:-/dev/null}"
else
  echo "[]"
fi
EOF
chmod +x "$FAKE_GH"

PATH="$TMP_DIR:$PATH"

BODY_OUT="$TMP_DIR/latest.md"

pass=0
fail=0

check_json() {
  local name="$1" field="$2" expected="$3" json="$4"
  local actual
  actual="$(printf '%s' "$json" | jq -r "$field")"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name (expected '$expected', got '$actual')"
    fail=$((fail + 1))
  fi
}

# Test 1: latest full review with low/medium findings -> act
cat > "$TMP_DIR/reviews.json" <<'EOF'
[
  {"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n\n### 🔵 Low Priority\n- something else\n"}
]
EOF
echo '[]' > "$TMP_DIR/comments.json"
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 1: full review acts" ".act" "true" "$result"
if [ -f "$BODY_OUT" ]; then
  echo "✅ Test 1: body file written"
  pass=$((pass + 1))
else
  echo "❌ Test 1: body file not written"
  fail=$((fail + 1))
fi

# Test 2: latest incremental review after a full -> act
cat > "$TMP_DIR/reviews.json" <<'EOF'
[
  {"id": 2, "submitted_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"},
  {"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"}
]
EOF
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 2: incremental review acts" ".act" "true" "$result"
check_json "Test 2: incremental count" ".incremental_count" "1" "$result"

# Test 3: latest skip-incremental issue comment after a full -> skip
cat > "$TMP_DIR/reviews.json" <<'EOF'
[
  {"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"}
]
EOF
cat > "$TMP_DIR/comments.json" <<'EOF'
[
  {"id": 100, "created_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "## 🤖 OpenCode CLI Code Review - Commit: `abc1234`\n\n⏭️ **Skipping INCREMENTAL review** - Existing blocking review from @github-actions[bot] requires full review for clearance."}
]
EOF
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 3: skip-incremental comment skips" ".act" "false" "$result"
check_json "Test 3: skip reason" ".skip_reason" "latest gate artifact is a skip-incremental comment" "$result"
check_json "Test 3: skip artifact timestamp" ".artifact_ts" "2026-01-02T00:00:00Z" "$result"
check_json "Test 3: skip body path empty" ".body_path // empty" "" "$result"

# Test 4: multiple issue-comment artifacts count until latest full
cat > "$TMP_DIR/reviews.json" <<'EOF'
[
  {"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"}
]
EOF
cat > "$TMP_DIR/comments.json" <<'EOF'
[
  {"id": 103, "created_at": "2026-01-04T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "## 🤖 OpenCode CLI Code Review - Commit: `abc1236`\n\n⏭️ **Skipping INCREMENTAL review** - Existing blocking review from @github-actions[bot] requires full review for clearance."},
  {"id": 102, "created_at": "2026-01-03T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"},
  {"id": 101, "created_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "## 🤖 OpenCode CLI Code Review - Commit: `abc1235`\n\n⏭️ **Skipping INCREMENTAL review** - Existing blocking review from @github-actions[bot] requires full review for clearance."}
]
EOF
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 4: multiple artifacts count until full" ".act" "false" "$result"
check_json "Test 4: incremental count is 3" ".incremental_count" "3" "$result"

# Test 5: cap exceeded (latest artifact is actionable incremental)
cat > "$TMP_DIR/reviews.json" <<'EOF'
[
  {"id": 3, "submitted_at": "2026-01-03T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"},
  {"id": 2, "submitted_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"},
  {"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"}
]
EOF
echo '[]' > "$TMP_DIR/comments.json"
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "1" "$BODY_OUT")"
check_json "Test 5: cap exceeded" ".act" "false" "$result"
check_json "Test 5: cap reason" ".skip_reason" "incremental cycle cap exceeded" "$result"
check_json "Test 5: cap body path empty" ".body_path // empty" "" "$result"

# Test 6: pagination - multiple arrays from gh api --paginate still see newest artifact
cat > "$TMP_DIR/reviews.json" <<'EOF'
[{"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"}]
[{"id": 2, "submitted_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something\n"}]
EOF
echo '[]' > "$TMP_DIR/comments.json"
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 6: pagination sees newest artifact" ".act" "true" "$result"
check_json "Test 6: pagination selects latest id" ".artifact_id" "2" "$result"

# Test 7: non-gate bot comments with Issues Summary are ignored
echo '[]' > "$TMP_DIR/reviews.json"
cat > "$TMP_DIR/comments.json" <<'EOF'
[
  {"id": 200, "created_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "## Other automation\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- unrelated"}
]
EOF
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 7: non-gate Issues Summary ignored" ".act" "false" "$result"
check_json "Test 7: no bogus body path" ".body_path // empty" "" "$result"

# Test 8: no artifacts returns no body path
echo '[]' > "$TMP_DIR/reviews.json"
echo '[]' > "$TMP_DIR/comments.json"
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 8: no artifacts skips" ".act" "false" "$result"
check_json "Test 8: no artifacts body path empty" ".body_path // empty" "" "$result"

# Test 9: cap boundary with actionable (INCREMENTAL) latest artifact.
# 3 INCREMENTAL + 1 FULL yields count=3. With cap=3, count==cap acts (-gt is
# false). With cap=2, count==cap+1 skips (-gt is true). This pins the -gt
# boundary that Test 5 (cap=1, count=2) does not cover.
cat > "$TMP_DIR/reviews.json" <<'EOF'
[
  {"id": 4, "submitted_at": "2026-01-04T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- x"},
  {"id": 3, "submitted_at": "2026-01-03T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- x"},
  {"id": 2, "submitted_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** INCREMENTAL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- x"},
  {"id": 1, "submitted_at": "2026-01-01T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\n**Review Type:** FULL\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- x"}
]
EOF
echo '[]' > "$TMP_DIR/comments.json"
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 9: cap boundary count==cap acts (3 cycles with cap=3)" ".act" "true" "$result"
check_json "Test 9: cap boundary count==cap counts 3" ".incremental_count" "3" "$result"
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "2" "$BODY_OUT")"
check_json "Test 9: cap boundary count==cap+1 skips (3 cycles with cap=2)" ".act" "false" "$result"
check_json "Test 9: cap boundary cap reason" ".skip_reason" "incremental cycle cap exceeded" "$result"

# Test 10: is_skip_incremental false-positive guard. A body with the gate
# header and "Skipping INCREMENTAL review" but WITHOUT "Existing blocking
# review" must NOT be treated as a skip-incremental artifact — the
# Issues Summary makes it actionable instead.
echo '[]' > "$TMP_DIR/reviews.json"
cat > "$TMP_DIR/comments.json" <<'EOF'
[
  {"id": 300, "created_at": "2026-01-02T00:00:00Z", "user": {"login": "github-actions[bot]"}, "body": "# 🤖 OpenCode CLI Code Review\n\nSkipping INCREMENTAL review - test fixture without the blocking-review marker.\n\n## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n- something"}
]
EOF
result="$(GH_FIXTURE_REVIEWS="$TMP_DIR/reviews.json" GH_FIXTURE_COMMENTS="$TMP_DIR/comments.json" "$HELPER" "owner/repo" "1" "3" "$BODY_OUT")"
check_json "Test 10: comment with one skip-incremental phrase acts (no false-positive skip)" ".act" "true" "$result"

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ]
