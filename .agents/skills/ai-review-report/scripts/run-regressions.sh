#!/bin/bash
# Run the same explicit, offline test list as the blocking GHA job.
# Deliberately not named test-*: the analyse gate auto-discovers that prefix,
# and must not recursively run this aggregate runner as an individual suite.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
  echo 'Tests require Bash >= 4.3. On macOS: brew install bash coreutils.' >&2
  exit 2
fi
case "${1:-}" in ''|--list) ;; *) echo "Usage: bash $0 [--list]" >&2; exit 64 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Preserve the selected shell without putting /usr/bin ahead of an activated
# Python virtualenv. Only bash is shadowed; python3 still resolves in that env.
ln -s "$BASH" "$work/bash"
export PATH="$work:$PATH"
if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
  coreutils="$(brew --prefix coreutils 2>/dev/null || true)"
  if [ -d "$coreutils/libexec/gnubin" ]; then export PATH="$coreutils/libexec/gnubin:$PATH"; fi
fi
for tool in git jq python3 timeout sort comm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing test prerequisite: $tool" >&2; exit 2; }
done
if ! timeout --version 2>/dev/null | grep -q 'GNU coreutils' || ! comm --version >/dev/null 2>&1; then
  echo 'GNU coreutils required (real timeout/process groups and comm -z). On macOS: brew install coreutils.' >&2
  exit 2
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "Missing PyYAML. Install $SCRIPT_DIR/requirements-test.txt into your test virtualenv." >&2
  exit 2
fi

# The workflow remains the single test-list source. Parse its literal array,
# never eval arbitrary shell text or launch the paid run-evals.sh runner.
python3 - "$REPO_ROOT/.github/workflows/llm-eval-harness.yml" > "$work/suites" <<'PY'
import re
import shlex
import sys
import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow["jobs"]["opencode-v2-regressions"]["steps"]
run = next(step["run"] for step in steps if step["name"] == "Run deterministic OpenCode v2 regressions")
match = re.search(r"(?ms)^tests=\(\n(.*?)^\)", run)
if match is None:
    raise SystemExit("Cannot find the blocking job test array")
suites = shlex.split(match.group(1), comments=True)
if not suites or len(suites) != len(set(suites)):
    raise SystemExit("Empty or duplicate blocking test list")
for suite in suites:
    if not re.fullmatch(r"(?:\.agents/skills/[a-z-]+/)?scripts/(?:eval/)?test-[a-z0-9-]+\.sh", suite):
        raise SystemExit(f"Not an offline test harness: {suite}")
    print(suite)
PY
if [ "${1:-}" = --list ]; then cat "$work/suites"; exit 0; fi

cd "$REPO_ROOT"
passed=0
failed=0
while IFS= read -r suite; do
  printf '\nRunning %s\n' "$suite"
  if "$BASH" "$suite"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi
done < "$work/suites"
printf '\nRegression suites: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
