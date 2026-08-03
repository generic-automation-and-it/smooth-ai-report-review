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
mkdir -p src __tests__ app/tests java scripts
printf 'v1\n' > src/app.js
printf 'v1\n' > src/app.test.ts
printf 'v1\n' > __tests__/thing.js
printf 'v1\n' > app/tests/handler_test.py
printf 'v1\n' > java/WidgetTest.java
printf 'v1\n' > src/Latest.cs          # NOT a test (lowercase "test") — must survive
printf 'v1\n' > vitest.config.ts
printf 'v1\n' > src/widget.test.e2e.ts # multi-dot test filename — must be matched/reverted
printf 'v1\n' > __tests__/deleteme_test.js # tracked test file the run will DELETE
printf 'v1\n' > src/obstruct.test.ts   # tracked test the run will replace with a DIRECTORY
printf 'v1\n' > scripts/test-review-chunk-threshold.sh  # test- prefix .sh — must be matched/reverted
printf 'v1\n' > scripts/test-helper.py                  # test- prefix .py — must be matched/reverted
printf 'v1\n' > scripts/test-helper-data.txt            # NOT a test (no matching extension) — must survive
# Eval harness (LADR-045 extension). None of these match any test-filename rule;
# they are caught only by the `evals?/` directory segment. The manifest is the
# one that matters most: it carries the must-catch recall label, so a fixer able
# to edit it can turn a failing eval green by relabelling the expectation.
mkdir -p scripts/eval/lib scripts/eval/corpus/must-catch/MC-001/after evals src/evaluation
printf 'v1\n' > scripts/eval/AGENTS.md
printf 'v1\n' > scripts/eval/run-evals.sh
printf 'v1\n' > scripts/eval/lib/score-review.sh
printf 'v1\n' > scripts/eval/corpus/must-catch/MC-001/manifest.json
printf 'v1\n' > scripts/eval/corpus/must-catch/MC-001/after/Handler.cs
printf 'v1\n' > evals/top-level.json                   # `evals/` plural at repo root
printf 'v1\n' > src/evaluate.ts                        # NOT an eval dir — must survive
printf 'v1\n' > src/evaluation/report.ts               # NOT `eval/` or `evals/` — must survive
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
printf 'v2\n' > src/widget.test.e2e.ts # multi-dot test edit — revert
rm __tests__/deleteme_test.js          # model DELETED a tracked test — must be restored
rm src/obstruct.test.ts && mkdir src/obstruct.test.ts && printf 'x\n' > src/obstruct.test.ts/blocker
                                       # model replaced a tracked test with a DIRECTORY — remove-and-retry must restore it
printf 'v2\n' > src/new_source.js      # new non-test file — keep
printf 'v2\n' > src/brand.spec.js      # new test file — revert (delete)
printf 'v2\n' > scripts/test-review-chunk-threshold.sh  # test- prefix .sh edit — revert
printf 'v2\n' > scripts/test-helper.py                  # test- prefix .py edit — revert
printf 'v2\n' > scripts/test-helper-data.txt            # non-test extension — keep
printf 'v2\n' > scripts/test-new-untracked.sh           # new untracked test- prefix .sh — revert (delete)
# Eval edits — all must be reverted via the `evals?/` directory segment.
printf 'v2\n' > scripts/eval/AGENTS.md                  # the file the PR #111 bad run actually edited
printf 'v2\n' > scripts/eval/run-evals.sh
printf 'v2\n' > scripts/eval/lib/score-review.sh        # the scorer that decides pass/fail
printf 'v2\n' > scripts/eval/corpus/must-catch/MC-001/manifest.json      # recall label
printf 'v2\n' > scripts/eval/corpus/must-catch/MC-001/after/Handler.cs   # corpus fixture
printf 'v2\n' > evals/top-level.json
mkdir -p scripts/eval/corpus/must-catch/MC-002-new
printf 'v2\n' > scripts/eval/corpus/must-catch/MC-002-new/manifest.json  # NEW untracked fixture — revert (delete)
# Near-miss paths that must survive — `eval` as a substring is not a match.
printf 'v2\n' > src/evaluate.ts
printf 'v2\n' > src/evaluation/report.ts

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
assert_content src/widget.test.e2e.ts v1     # multi-dot test filename matched + reverted
assert_content __tests__/deleteme_test.js v1  # DELETED tracked test file restored to HEAD
assert_content src/obstruct.test.ts v1        # file-replaced-by-dir: remove-and-retry restored it (and it is a file again)
[ -f src/obstruct.test.ts ] || { echo "FAIL: src/obstruct.test.ts should be a regular file after revert" >&2; exit 1; }
assert_absent src/brand.spec.js
# test- prefix patterns (LADR-057):
assert_content scripts/test-review-chunk-threshold.sh v1  # test- prefix .sh matched + reverted
assert_content scripts/test-helper.py v1                  # test- prefix .py matched + reverted
assert_absent scripts/test-new-untracked.sh               # untracked test- prefix .sh removed
# Eval harness (LADR-045 extension) — reverted via the `evals?/` dir segment:
assert_content scripts/eval/AGENTS.md v1
assert_content scripts/eval/run-evals.sh v1
assert_content scripts/eval/lib/score-review.sh v1
assert_content scripts/eval/corpus/must-catch/MC-001/manifest.json v1
assert_content scripts/eval/corpus/must-catch/MC-001/after/Handler.cs v1
assert_content evals/top-level.json v1
assert_absent scripts/eval/corpus/must-catch/MC-002-new/manifest.json   # new untracked fixture removed
# Preserved:
assert_content src/app.js v2
assert_content src/Latest.cs v2
assert_content src/new_source.js v2
assert_content scripts/test-helper-data.txt v2            # non-test extension preserved
assert_content src/evaluate.ts v2                         # "evaluate" is not an eval DIR
assert_content src/evaluation/report.ts v2                # "evaluation/" is not "eval/" or "evals/"

# Reverted list on stdout must name each reverted path and nothing else.
for p in src/app.test.ts __tests__/thing.js app/tests/handler_test.py java/WidgetTest.java vitest.config.ts src/widget.test.e2e.ts __tests__/deleteme_test.js src/obstruct.test.ts src/brand.spec.js scripts/test-review-chunk-threshold.sh scripts/test-helper.py \
         scripts/eval/AGENTS.md scripts/eval/run-evals.sh scripts/eval/lib/score-review.sh \
         scripts/eval/corpus/must-catch/MC-001/manifest.json scripts/eval/corpus/must-catch/MC-001/after/Handler.cs \
         evals/top-level.json; do
  printf '%s\n' "$out" | grep -qx "$p" || { echo "FAIL: '$p' missing from reverted list" >&2; exit 1; }
done
printf '%s\n' "$out" | grep -qx src/app.js && { echo "FAIL: non-test file listed as reverted" >&2; exit 1; }
printf '%s\n' "$out" | grep -qx scripts/test-helper-data.txt && { echo "FAIL: non-test extension listed as reverted" >&2; exit 1; }
printf '%s\n' "$out" | grep -qx src/evaluate.ts && { echo "FAIL: 'evaluate.ts' false-matched the eval rule" >&2; exit 1; }
printf '%s\n' "$out" | grep -qx src/evaluation/report.ts && { echo "FAIL: 'evaluation/' false-matched the eval rule" >&2; exit 1; }

echo "✓ default mode reverts test/eval edits, preserves the rest"

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
