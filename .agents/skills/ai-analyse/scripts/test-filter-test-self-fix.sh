#!/bin/bash
# Offline regression coverage for filter-test-self-fix.sh: verifies that test /
# test-framework edits are reverted by default and preserved when self-fix of
# tests is explicitly enabled, while non-test edits always survive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/lib/filter-test-self-fix.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repo="${tmp_dir}/repo"
mkdir -p "$repo"
cd "$repo"
git init -q
git config user.email t@e.st
git config user.name tester

# Committed baseline: a source file, a test file, and a JVM-style test class.
mkdir -p src __tests__ app/tests java
printf 'v1\n' > src/app.js
printf 'v1\n' > src/app.test.ts
printf 'v1\n' > __tests__/thing.js
printf 'v1\n' > app/tests/handler_test.py
printf 'v1\n' > java/WidgetTest.java
printf 'v1\n' > src/Latest.cs          # NOT a test (lowercase "test") — must survive
printf 'v1\n' > vitest.config.ts
git add -A
git commit -qm baseline

# Simulate an ai-analyse run: it edits source AND tests, deletes a test,
# and creates a brand-new test file + a new source file.
printf 'v2\n' > src/app.js             # non-test edit — keep
printf 'v2\n' > src/app.test.ts        # test edit — revert
printf 'v2\n' > __tests__/thing.js     # test-dir edit — revert
printf 'v2\n' > app/tests/handler_test.py  # test edit — revert
printf 'v2\n' > java/WidgetTest.java   # JVM test edit — revert
printf 'v2\n' > src/Latest.cs          # non-test edit — keep
printf 'v2\n' > vitest.config.ts       # framework config edit — revert
rm __tests__/deleteme_test.js 2>/dev/null || true
printf 'v2\n' > src/new_source.js      # new non-test file — keep
printf 'v2\n' > src/brand.spec.js      # new test file — revert (delete)

# Snapshot working tree, then run the guard in default (off) mode.
out="$(OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX="" bash "$HELPER" 2>/dev/null)"

assert_content() {
  local file="$1" expected="$2"
  local actual; actual="$(cat "$file" 2>/dev/null || echo '<missing>')"
  [ "$actual" = "$expected" ] || { echo "FAIL: $file expected '$expected' got '$actual'" >&2; exit 1; }
}
assert_absent() {
  [ ! -e "$1" ] || { echo "FAIL: $1 should have been removed" >&2; exit 1; }
}

# Reverted to baseline:
assert_content src/app.test.ts v1
assert_content __tests__/thing.js v1
assert_content app/tests/handler_test.py v1
assert_content java/WidgetTest.java v1
assert_content vitest.config.ts v1
assert_absent src/brand.spec.js
# Preserved:
assert_content src/app.js v2
assert_content src/Latest.cs v2
assert_content src/new_source.js v2

# Reverted list on stdout must name each reverted path and nothing else.
for p in src/app.test.ts __tests__/thing.js app/tests/handler_test.py java/WidgetTest.java vitest.config.ts src/brand.spec.js; do
  printf '%s\n' "$out" | grep -qx "$p" || { echo "FAIL: '$p' missing from reverted list" >&2; exit 1; }
done
printf '%s\n' "$out" | grep -qx src/app.js && { echo "FAIL: non-test file listed as reverted" >&2; exit 1; }

echo "✓ default mode reverts test/test-framework edits, preserves the rest"

# Now the allow path: re-apply the edits and confirm nothing is reverted.
git checkout -q -- .
printf 'v2\n' > src/app.test.ts
printf 'v2\n' > src/app.js
out_allow="$(OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX="true" bash "$HELPER" 2>/dev/null)"
[ -z "$out_allow" ] || { echo "FAIL: allow mode should revert nothing, got '$out_allow'" >&2; exit 1; }
assert_content src/app.test.ts v2
assert_content src/app.js v2
echo "✓ allow mode (OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX=true) preserves test edits"

echo "✓ filter-test-self-fix tests passed"
