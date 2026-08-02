#!/bin/bash
# Offline regression coverage for run-test-gate.sh (LADR-057).
#
# The gate is REGRESSION-RELATIVE: a suite that already fails at HEAD must not
# block the push, and a suite that passes at HEAD but fails against the model's
# working-tree edits must. Tests 2 and 8 are the two halves of that contract —
# an absolute-gating implementation passes test 2 and fails test 8, so keep both.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/lib/run-test-gate.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repo="${tmp_dir}/repo"
mkdir -p "$repo"
cd "$repo"
git init -q
git config user.email t@e.st
git config user.name tester

failures_dir="${tmp_dir}/failures"

# Helper: run the gate and return the exit code.
run_gate() {
  local report="$1"
  local rc=0
  bash "$GATE" "$report" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# ── Test 1: green path (all suites pass) ──────────────────────
mkdir -p scripts
printf '#!/bin/bash\nexit 0\n' > scripts/test-green.sh
chmod +x scripts/test-green.sh
git add -A && git commit -qm green-baseline

report="$tmp_dir/report1.txt"
rc="$(run_gate "$report")"
[ "$rc" = "0" ] || { echo "FAIL Test1: expected exit 0 got $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=pass' "$report" || { echo "FAIL Test1: expected pass in report" >&2; exit 1; }
echo "✓ Test 1: green path"

# ── Test 2: a suite already red AT HEAD does not block ────────
# Regression-relative gating: the fixer did not break this, so it must not be
# punished for it. Absolute gating would exit 1 here and permanently disable the
# autonomous loop the first time any suite went stale.
git checkout -q -- . 2>/dev/null || true
printf '#!/bin/bash\nexit 1\n' > scripts/test-red.sh
chmod +x scripts/test-red.sh
git add -A && git commit -qm preexisting-red

report="$tmp_dir/report2.txt"
rc="$(run_gate "$report")"
[ "$rc" = "0" ] || { echo "FAIL Test2: pre-existing failure must not block, got exit $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=pass' "$report" || { echo "FAIL Test2: expected pass" >&2; exit 1; }
grep -q 'PREEXISTING_SUITE=scripts/test-red.sh' "$report" || {
  echo "FAIL Test2: pre-existing failure must still be reported" >&2; exit 1; }
grep -q '^FAILED_SUITE=' "$report" && {
  echo "FAIL Test2: pre-existing failure must not be listed as a regression" >&2; exit 1; }
echo "✓ Test 2: pre-existing failure reported but not blocking"

# ── Test 3: no suites tracked at HEAD ─────────────────────────────────
git checkout -q -- . 2>/dev/null || true
rm -f scripts/test-green.sh scripts/test-red.sh
git add -A && git commit -qm no-suites

report="$tmp_dir/report3.txt"
rc="$(run_gate "$report")"
[ "$rc" = "0" ] || { echo "FAIL Test3: expected exit 0 got $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=no-suites' "$report" || { echo "FAIL Test3: expected no-suites in report" >&2; exit 1; }
echo "✓ Test 3: no suites detected"

# ── Test 4: explicit command ──────────────────────────────────
git checkout -q -- . 2>/dev/null || true
printf '#!/bin/bash\nexit 0\n' > scripts/test-green.sh
chmod +x scripts/test-green.sh
git add -A && git commit -qm explicit-cmd-baseline

report="$tmp_dir/report4.txt"
rc="$(OPENCODE_ANALYSE_TEST_COMMAND="echo hello" run_gate "$report")"
[ "$rc" = "0" ] || { echo "FAIL Test4: expected exit 0 got $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=pass' "$report" || { echo "FAIL Test4: expected pass in report" >&2; exit 1; }
echo "✓ Test 4: explicit command"

# ── Test 5: explicit command fails ────────────────────────────
report="$tmp_dir/report5.txt"
rc="$(OPENCODE_ANALYSE_TEST_COMMAND="exit 1" run_gate "$report")"
[ "$rc" = "1" ] || { echo "FAIL Test5: expected exit 1 got $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=fail' "$report" || { echo "FAIL Test5: expected fail in report" >&2; exit 1; }
grep -q 'FAILED_SUITE=OPENCODE_ANALYSE_TEST_COMMAND' "$report" || { echo "FAIL Test5: expected explicit command failure" >&2; exit 1; }
echo "✓ Test 5: explicit command fails"

# ── Test 6: untracked test script is NOT executed (security) ──────────
git checkout -q -- . 2>/dev/null || true
rm -f scripts/test-green.sh
git add -A && git commit -qm untracked-baseline

# An untracked script that would fail — and, if it were ever executed, would
# also prove the model can get arbitrary code run with the job's tokens.
printf '#!/bin/bash\nexit 1\n' > scripts/test-untracked.sh
chmod +x scripts/test-untracked.sh
# Deliberately NOT git added.

report="$tmp_dir/report6.txt"
rc="$(run_gate "$report")"
[ "$rc" = "0" ] || { echo "FAIL Test6: expected exit 0 (no suites) got $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=no-suites' "$report" || { echo "FAIL Test6: expected no-suites" >&2; exit 1; }
echo "✓ Test 6: untracked script not executed"

# ── Test 7: timeout is red, and is NEVER excused as pre-existing ──────
# The slow suite is committed, so its HEAD baseline would also time out. A
# timeout means the gate could not establish safety, so it must fail closed.
git checkout -q -- . 2>/dev/null || true
rm -f scripts/test-untracked.sh
printf '#!/bin/bash\nsleep 30\n' > scripts/test-slow.sh
chmod +x scripts/test-slow.sh
git add -A && git commit -qm slow-baseline

report="$tmp_dir/report7.txt"
rc="$(OPENCODE_ANALYSE_TEST_TIMEOUT=2 run_gate "$report")"
[ "$rc" = "1" ] || { echo "FAIL Test7: timeout must block, got exit $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=fail' "$report" || { echo "FAIL Test7: expected fail in report" >&2; exit 1; }
grep -q 'FAILED_SUITE=scripts/test-slow.sh' "$report" || {
  echo "FAIL Test7: timed-out suite must be a regression, not pre-existing" >&2; exit 1; }
grep -q 'TIMEOUT' "${failures_dir}/scripts/test-slow.sh.log" || {
  echo "FAIL Test7: expected TIMEOUT in the failure log" >&2; exit 1; }
echo "✓ Test 7: timeout blocks and is never excused"

# ── Test 8: a suite green at HEAD, red in the working tree, BLOCKS ────
# This is the af74df1 / 4b1ad8a scenario the gate exists for: the model edits a
# tracked file, the suite that covered it goes green → red, nothing is pushed.
git checkout -q -- . 2>/dev/null || true
rm -f scripts/test-slow.sh
printf '#!/bin/bash\nexit 0\n' > scripts/test-regress.sh
chmod +x scripts/test-regress.sh
git add -A && git commit -qm regression-baseline

# The "model edit": the tracked suite now fails, uncommitted.
printf '#!/bin/bash\nexit 1\n' > scripts/test-regress.sh

report="$tmp_dir/report8.txt"
rc="$(run_gate "$report")"
[ "$rc" = "1" ] || { echo "FAIL Test8: a green→red regression must block, got exit $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=fail' "$report" || { echo "FAIL Test8: expected fail" >&2; exit 1; }
grep -q 'FAILED_SUITE=scripts/test-regress.sh' "$report" || {
  echo "FAIL Test8: expected the regressed suite in the report" >&2; exit 1; }
grep -q '^PREEXISTING_SUITE=' "$report" && {
  echo "FAIL Test8: a regression must not be classified pre-existing" >&2; exit 1; }
[ -f "${failures_dir}/scripts/test-regress.sh.log" ] || {
  echo "FAIL Test8: expected a failure log for the regression" >&2; exit 1; }
echo "✓ Test 8: green→red regression blocks the push"

# ── Test 9: the pristine baseline must not see the working-tree edit ──
# Guards the mechanism behind tests 2 and 8: the HEAD re-run happens in a
# separate worktree, so an edit in the main tree cannot leak into it. If it did,
# every regression would look pre-existing and the gate would be a no-op.
git checkout -q -- . 2>/dev/null || true
printf '#!/bin/bash\n[ -f marker.txt ] && exit 1\nexit 0\n' > scripts/test-regress.sh
git add -A && git commit -qm marker-baseline
: > marker.txt   # untracked working-tree state the HEAD checkout must not have

report="$tmp_dir/report9.txt"
rc="$(run_gate "$report")"
[ "$rc" = "1" ] || { echo "FAIL Test9: expected the marker-driven failure to block, got $rc" >&2; exit 1; }
grep -q 'FAILED_SUITE=scripts/test-regress.sh' "$report" || {
  echo "FAIL Test9: working-tree state leaked into the HEAD baseline" >&2; exit 1; }
rm -f marker.txt
echo "✓ Test 9: HEAD baseline is isolated from the working tree"

# ── Test 10: invalid timeout / log-lines fall back instead of crashing ──
git checkout -q -- . 2>/dev/null || true
printf '#!/bin/bash\nexit 0\n' > scripts/test-regress.sh
git add -A && git commit -qm validation-baseline

report="$tmp_dir/report10.txt"
rc="$(OPENCODE_ANALYSE_TEST_TIMEOUT="not-a-number" OPENCODE_ANALYSE_TEST_LOG_LINES="-5" run_gate "$report")"
[ "$rc" = "0" ] || { echo "FAIL Test10: invalid config should fall back, got exit $rc" >&2; exit 1; }
grep -q 'GATE_STATUS=pass' "$report" || { echo "FAIL Test10: expected pass" >&2; exit 1; }
echo "✓ Test 10: invalid timeout / log-lines fall back to defaults"

echo "✓ run-test-gate.sh tests passed"
