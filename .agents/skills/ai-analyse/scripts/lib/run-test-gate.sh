#!/bin/bash
# run-test-gate.sh — deterministic test gate for ai-analyse (LADR-057).
#
# After the model edits and the filter-test-self-fix.sh revert, this script runs
# the project's test suites to verify the fixes did not break anything. If any
# suite REGRESSED, the commit is not pushed.
#
# Gating is REGRESSION-RELATIVE, not absolute. A suite that already fails at
# HEAD keeps failing after the model's edits through no fault of the fixer;
# blocking on it would disable the autonomous loop permanently the first time
# any suite goes stale. So every failing suite is re-run in a pristine worktree
# checked out at HEAD:
#
#   fails after edits + passes at HEAD  → REGRESSION  → blocking
#   fails after edits + fails at HEAD   → PRE-EXISTING → reported, not blocking
#
# If the pristine re-run cannot be performed (worktree creation fails), the
# suite is classified as a regression — fail closed.
#
# Inputs (env vars):
#   OPENCODE_ANALYSE_TEST_COMMAND   - explicit shell command to run (overrides auto-detect)
#   OPENCODE_ANALYSE_TEST_TIMEOUT   - budget in seconds for the WHOLE gate (default 600)
#   OPENCODE_ANALYSE_TEST_LOG_LINES - lines of failure output kept per suite (default 40)
#
# Args:
#   $1 - report file path (machine-readable result written here)
#
# Report file keys:
#   GATE_STATUS=pass|fail|no-suites
#   FAILED_SUITE=<path>        one per blocking regression
#   PREEXISTING_SUITE=<path>   one per non-blocking pre-existing failure
#
# Exit code: 0 when nothing regressed (including no-suites and pre-existing-only),
#            1 when at least one suite regressed, 2 on usage error.
set -euo pipefail

report_file="${1:-}"
if [ -z "$report_file" ]; then
  echo "run-test-gate.sh: report file path required as \$1" >&2
  exit 2
fi

mkdir -p "$(dirname "$report_file")"

# Whole-gate budget. Non-integer / <= 0 falls back to the default, mirroring the
# validation pattern used for OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT.
timeout_raw="${OPENCODE_ANALYSE_TEST_TIMEOUT:-600}"
case "$timeout_raw" in
  ''|*[!0-9]*) timeout_sec=600 ;;
  *) timeout_sec="$timeout_raw" ;;
esac
[ "$timeout_sec" -gt 0 ] 2>/dev/null || timeout_sec=600

log_raw="${OPENCODE_ANALYSE_TEST_LOG_LINES:-40}"
case "$log_raw" in
  ''|*[!0-9]*) log_lines=40 ;;
  *) log_lines="$log_raw" ;;
esac
[ "$log_lines" -gt 0 ] 2>/dev/null || log_lines=40

failures_dir="$(dirname "$report_file")/failures"
mkdir -p "$failures_dir"

gate_start="$SECONDS"
# Seconds left in the whole-gate budget; never returns less than 1 so `timeout`
# is always given a valid argument (an exhausted budget is handled by the caller).
remaining_budget() {
  local left=$(( timeout_sec - (SECONDS - gate_start) ))
  [ "$left" -gt 0 ] || left=0
  printf '%s' "$left"
}

# Mode 1: explicit command overrides everything.
if [ -n "${OPENCODE_ANALYSE_TEST_COMMAND:-}" ]; then
  echo "Running OPENCODE_ANALYSE_TEST_COMMAND (budget ${timeout_sec}s)"
  tmp="${report_file}.tmp"
  exit_code=0
  timeout "${timeout_sec}s" bash -c "${OPENCODE_ANALYSE_TEST_COMMAND}" >"$tmp" 2>&1 || exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    printf 'GATE_STATUS=pass\n' > "$report_file"
    rm -f "$tmp"
    exit 0
  fi
  printf 'GATE_STATUS=fail\n' > "$report_file"
  printf 'FAILED_SUITE=OPENCODE_ANALYSE_TEST_COMMAND\n' >> "$report_file"
  if [ "$exit_code" -eq 124 ]; then
    printf 'TIMEOUT after %s seconds\n' "$timeout_sec" > "${failures_dir}/OPENCODE_ANALYSE_TEST_COMMAND.log"
  else
    tail -n "${log_lines}" "$tmp" > "${failures_dir}/OPENCODE_ANALYSE_TEST_COMMAND.log"
  fi
  rm -f "$tmp"
  exit 1
fi

# Mode 2: auto-detect test suites TRACKED AT HEAD.
#
# SECURITY: candidates come from `git ls-tree`, never a filesystem glob. The
# model that just edited this tree could otherwise drop in a `test-evil.sh` and
# have the gate execute it with the job's tokens in the environment. A newly
# created, untracked test script is never run.
#
# A temp file rather than process substitution: /dev/fd is not always present.
candidates_file="$(mktemp)"
sorted_file="$(mktemp)"
worktree_dir=""
cleanup() {
  rm -f "$candidates_file" "$sorted_file"
  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || rm -rf "$worktree_dir"
  fi
}
trap cleanup EXIT

git ls-tree -r HEAD --name-only > "$candidates_file"
grep -E '(^|/)test-[A-Za-z0-9][A-Za-z0-9_.-]*\.(sh|bash|bats|ps1|py|js|mjs|ts)$' \
  "$candidates_file" 2>/dev/null | LC_ALL=C sort > "$sorted_file" || true

if [ ! -s "$sorted_file" ]; then
  printf 'GATE_STATUS=no-suites\n' > "$report_file"
  echo "No test suites detected. Set OPENCODE_ANALYSE_TEST_COMMAND to enable the test gate."
  exit 0
fi

# Pristine checkout of HEAD, used to decide whether a failure is a regression or
# was already there. Created lazily: when everything is green it is never made.
pristine_root() {
  if [ -n "$worktree_dir" ]; then
    printf '%s' "$worktree_dir"
    return 0
  fi
  local candidate
  candidate="$(mktemp -d)"
  rm -rf "$candidate"
  if git worktree add --detach "$candidate" HEAD >/dev/null 2>&1; then
    worktree_dir="$candidate"
    printf '%s' "$worktree_dir"
    return 0
  fi
  rm -rf "$candidate"
  return 1
}

# Run one suite, echo its exit code. $2 is the directory to run from.
run_suite() {
  local suite="$1" root="$2" out="$3" budget rc=0
  budget="$(remaining_budget)"
  if [ "$budget" -le 0 ]; then
    printf '124'
    return 0
  fi
  ( cd "$root" && timeout "${budget}s" bash "$suite" ) >"$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

regressions=()
preexisting=()
repo_root="$(pwd)"
tmp_out="${report_file}.tmp"

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  if [ "$(remaining_budget)" -le 0 ]; then
    echo "  ✗ ${suite} SKIPPED — whole-gate budget of ${timeout_sec}s exhausted"
    regressions+=("$suite")
    mkdir -p "$(dirname "${failures_dir}/${suite}.log")"
    printf 'Not run: the %ss whole-gate budget was exhausted by earlier suites.\n' \
      "$timeout_sec" > "${failures_dir}/${suite}.log"
    continue
  fi

  echo "Running test suite: ${suite}"
  exit_code="$(run_suite "$suite" "$repo_root" "$tmp_out")"

  if [ "$exit_code" -eq 0 ]; then
    echo "  ✓ ${suite} passed"
    continue
  fi

  # Failed. Decide regression vs pre-existing by re-running against HEAD.
  mkdir -p "$(dirname "${failures_dir}/${suite}.log")"
  if [ "$exit_code" -eq 124 ]; then
    printf 'TIMEOUT — the whole-gate budget of %s seconds elapsed while this suite was running.\n' \
      "$timeout_sec" > "${failures_dir}/${suite}.log"
  else
    tail -n "${log_lines}" "$tmp_out" > "${failures_dir}/${suite}.log"
  fi

  # A timeout is never excused as pre-existing. It means the gate could not
  # establish whether the tree is safe, and "unknown" must fail closed —
  # otherwise a fix that introduces an infinite loop reads as "already slow".
  if [ "$exit_code" -eq 124 ]; then
    echo "  ✗ ${suite} TIMED OUT — treated as a regression (safety could not be established)"
    regressions+=("$suite")
    continue
  fi

  if pristine=$(pristine_root); then
    baseline_out="${report_file}.baseline"
    baseline_code="$(run_suite "$suite" "$pristine" "$baseline_out")"
    rm -f "$baseline_out"
    if [ "$baseline_code" -ne 0 ]; then
      if [ "$baseline_code" -eq 124 ]; then
        echo "  ! ${suite} baseline TIMED OUT — safety could not be established, treating as a regression (fail closed)"
      else
        echo "  ~ ${suite} FAILED (exit ${exit_code}) — already failing at HEAD, not a regression"
        preexisting+=("$suite")
        continue
      fi
    fi
  else
    echo "  ! could not create a pristine worktree — treating ${suite} as a regression (fail closed)"
    printf '\n[gate] Could not verify against HEAD; classified as a regression.\n' \
      >> "${failures_dir}/${suite}.log"
  fi

  echo "  ✗ ${suite} REGRESSED (exit ${exit_code}) — passes at HEAD, fails after the fixes"
  regressions+=("$suite")
done < "$sorted_file"

rm -f "$tmp_out"

{
  if [ "${#regressions[@]}" -eq 0 ]; then
    printf 'GATE_STATUS=pass\n'
  else
    printf 'GATE_STATUS=fail\n'
  fi
  for suite in ${regressions[@]+"${regressions[@]}"}; do
    printf 'FAILED_SUITE=%s\n' "$suite"
  done
  for suite in ${preexisting[@]+"${preexisting[@]}"}; do
    printf 'PREEXISTING_SUITE=%s\n' "$suite"
  done
} > "$report_file"

if [ "${#preexisting[@]}" -gt 0 ]; then
  echo "${#preexisting[@]} suite(s) were already failing at HEAD and did not block the push."
fi

[ "${#regressions[@]}" -eq 0 ] || exit 1
exit 0
