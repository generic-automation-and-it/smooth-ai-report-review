#!/bin/bash
# filter-test-self-fix.sh — enforce the "test in the loop" policy for ai-analyse.
#
# The autonomous low/medium auto-fixer must NOT modify tests, the test
# framework, or eval harnesses by default. Tests are the independent oracle that
# proves (or disproves) that an automated fix did not break anything; if the
# same run that applies a fix is also free to rewrite the tests, a wrong fix can
# silently rewrite the very tests that would have caught it and still go green.
# Eval corpora, manifests and scorers are the same oracle one level up — they
# are what proves the *reviewer* still works — so they are covered too.
#
# This is the DETERMINISTIC guard: the analyse model is untrusted, so the SKILL
# prompt asking it to leave tests alone is only advisory. This script runs in
# the workflow after the model edits and, unless self-fix of tests is explicitly
# enabled, reverts any change the model made to a test, test-framework, or eval
# file
# (restoring tracked files to HEAD, deleting newly-created untracked ones)
# BEFORE the commit step stages anything. Non-test edits are left untouched.
#
# Enable test/eval self-fix by setting the GitHub Variable
# OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX to a truthy value (1/true/yes/on).
#
# Operates on the git working tree in the current directory. Prints one reverted
# path per line to stdout (empty when nothing was reverted or self-fix is
# allowed); human-readable progress goes to stderr.
set -euo pipefail

allow_raw="${OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX:-}"
case "$(printf '%s' "$allow_raw" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)
    echo "OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX is enabled; test/eval edits are permitted." >&2
    exit 0
    ;;
esac

# Scratch/tooling paths the workflow never commits — also never in scope here.
PATHSPEC=( . ':(exclude)ci_temp' ':(exclude).context' ':(exclude).smooth-ai-review-tools' )

# Case-insensitive matcher: test directories, JS/TS/Python test-file naming, and
# common test-framework config/setup files.
#
# `evals?/` is in the same list, and for the same reason. An eval harness is a
# test of the reviewer: its corpus fixtures are the inputs, its manifests are
# the expected results, and its scorer decides pass/fail. A fixer free to edit
# them can turn a failing eval green by relabelling the expectation, which is
# the eval-side twin of making a red test pass — already forbidden for tests by
# LADR-056. Measured before this rule existed, 50 of the 51 files under this
# repo's own `scripts/eval/` were unguarded (only `test-evals.sh`, and only by
# accident of the `test-` prefix rule below).
#
# Matching the DIRECTORY segment rather than filenames is deliberate: harness,
# scorer, corpus and manifests all live under `eval/` and share no naming
# convention. It is deliberately broad — a consumer's production `src/eval/`
# is caught too. For an edit guard that is the safe direction: the failure mode
# is "a Medium/Low fix was not applied", it is reported in the summary comment,
# and a human or /ai-review can still make the change.
CI_RE='(^|/)(__tests__|__mocks__|tests?|specs?|evals?|e2e|cypress|playwright|\.storybook)/'
CI_RE+='|\.(test|spec)\.[A-Za-z0-9.]+$'
CI_RE+='|(^|/)test_[A-Za-z0-9][A-Za-z0-9_]*\.py$'
CI_RE+='|(^|/)[A-Za-z0-9][A-Za-z0-9_.-]*_test\.[A-Za-z0-9]+$'
CI_RE+='|(^|/)test-[A-Za-z0-9][A-Za-z0-9_.-]*\.(sh|bash|bats|ps1|py|js|mjs|ts)$'
CI_RE+='|(^|/)(conftest\.py|pytest\.ini|tox\.ini|phpunit\.xml(\.dist)?'
CI_RE+='|jest\.(config|setup)\.[A-Za-z0-9.]+|vitest\.(config|setup|workspace)\.[A-Za-z0-9.]+'
CI_RE+='|playwright\.config\.[A-Za-z0-9.]+|cypress\.(config\.[A-Za-z0-9.]+|json)'
CI_RE+='|karma\.conf\.[A-Za-z0-9.]+|wdio\.conf\.[A-Za-z0-9.]+|jasmine\.json'
CI_RE+='|\.mocharc[A-Za-z0-9.]*|\.rspec)$'

# Case-sensitive matcher: JVM/.NET capitalized test-class suffixes (kept
# case-sensitive so "Commit.java" / "Latest.cs" / "Audit.cs" do not false-match).
CS_RE='(^|/)[A-Za-z0-9_$]*(Test|Tests|Spec|Specs|IT|ITCase)\.(java|kt|kts|scala|groovy|cs|fs|fsx|vb)$'

is_test_path() {
  local p="$1"
  printf '%s\n' "$p" | grep -iEq "$CI_RE" && return 0
  printf '%s\n' "$p" | grep -Eq "$CS_RE" && return 0
  return 1
}

# Tracked files that differ from HEAD (modified/added-to-index/deleted), plus
# untracked additions. NUL-delimited for path safety. Written to temp files and
# read back with plain redirection so we don't depend on /dev/fd process
# substitution (absent on some minimal runners).
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git diff --name-only -z HEAD -- "${PATHSPEC[@]}" > "${scratch}/tracked" 2>/dev/null || true
git ls-files --others --exclude-standard -z -- "${PATHSPEC[@]}" > "${scratch}/untracked" 2>/dev/null || true

tracked=()
while IFS= read -r -d '' p; do tracked+=( "$p" ); done < "${scratch}/tracked"
untracked=()
while IFS= read -r -d '' p; do untracked+=( "$p" ); done < "${scratch}/untracked"

# Restore a tracked test file to HEAD, fail-closed. The common path is a plain
# `git checkout`. If that is obstructed — e.g. the model replaced the file with
# a directory or symlink — remove the obstruction and retry, so the model's edit
# still cannot survive to the commit. Only a still-failing retry aborts the step
# (the ultimate fail-closed outcome); we never "warn and continue", which would
# let the test edit through and defeat the guard.
revert_tracked_test() {
  local p="$1"
  if git checkout HEAD -- "$p" 2>/dev/null; then
    return 0
  fi
  echo "warning: could not restore '$p' via git checkout (obstructed?); removing and retrying" >&2
  rm -rf -- "$p"
  git checkout HEAD -- "$p"
}

reverted=()
for p in "${tracked[@]:-}"; do
  [ -n "$p" ] || continue
  if is_test_path "$p"; then
    revert_tracked_test "$p"
    reverted+=( "$p" )
  fi
done
for p in "${untracked[@]:-}"; do
  [ -n "$p" ] || continue
  if is_test_path "$p"; then
    # -rf so an untracked test *directory* is removed too (rm -f fails on a dir).
    rm -rf -- "$p"
    reverted+=( "$p" )
  fi
done

if [ "${#reverted[@]}" -eq 0 ]; then
  echo "No test/eval edits to revert." >&2
  exit 0
fi

echo "Reverted ${#reverted[@]} test/eval edit(s) (OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX off):" >&2
for p in "${reverted[@]}"; do
  echo " - $p" >&2
  printf '%s\n' "$p"
done
