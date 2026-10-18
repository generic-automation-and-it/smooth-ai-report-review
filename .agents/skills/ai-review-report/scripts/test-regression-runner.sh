#!/bin/bash
# The local runner must execute the CI list, preserve its Python env, and fail
# on a red suite. Its fixtures contain only harmless local sentinel scripts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
scripts="$repo/.agents/skills/ai-review-report/scripts"
mkdir -p "$scripts/eval" "$repo/.github/workflows" "$scratch/venv/bin"
cp "$here/run-regressions.sh" "$scripts/"
real_python="$(command -v python3)"
cat > "$scratch/venv/bin/python3" <<EOF
#!/bin/sh
printf 'python\n' >> "$scratch/python-selected"
exec "$real_python" "\$@"
EOF
chmod +x "$scratch/venv/bin/python3"
export PATH="$scratch/venv/bin:$PATH"
cat > "$scripts/test-sentinel.sh" <<EOF
#!/bin/sh
printf 'one\n' >> "$scratch/executed"
EOF
cat > "$scripts/eval/test-sentinel.sh" <<EOF
#!/bin/sh
printf 'two\n' >> "$scratch/executed"
EOF
cat > "$repo/.github/workflows/llm-eval-harness.yml" <<'YAML'
jobs:
  opencode-v2-regressions:
    steps:
      - name: Run deterministic OpenCode v2 regressions
        run: |
          tests=(
            # The actual literal CI list, not a filesystem glob.
            .agents/skills/ai-review-report/scripts/test-sentinel.sh
            .agents/skills/ai-review-report/scripts/eval/test-sentinel.sh
          )
YAML
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
"$BASH" "$scripts/run-regressions.sh" --list > "$scratch/list"
[ "$(wc -l < "$scratch/list" | tr -d ' ')" = 2 ] || fail 'did not extract both CI entries'
[ ! -e "$scratch/executed" ] || fail '--list executed a test'
[ -s "$scratch/python-selected" ] || fail 'runner shadowed the selected Python env'
"$BASH" "$scripts/run-regressions.sh" > "$scratch/green.out" 2>&1
grep -q '2 passed, 0 failed' "$scratch/green.out" || fail 'did not run the full declared list'
[ "$(wc -l < "$scratch/executed" | tr -d ' ')" = 2 ] || fail 'executed the wrong number of suites'
printf '#!/bin/sh\nexit 1\n' > "$scripts/test-sentinel.sh"
rc=0
"$BASH" "$scripts/run-regressions.sh" > "$scratch/red.out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail 'a failing suite did not make the runner fail'
grep -q '1 passed, 1 failed' "$scratch/red.out" || fail 'runner hid a failure or skipped later tests'
# A future YAML edit cannot turn this offline runner into a paid eval entrypoint.
sed 's@eval/test-sentinel.sh@eval/run-evals.sh@' \
  "$repo/.github/workflows/llm-eval-harness.yml" > "$scratch/paid.yml"
mv "$scratch/paid.yml" "$repo/.github/workflows/llm-eval-harness.yml"
rc=0
"$BASH" "$scripts/run-regressions.sh" --list > "$scratch/paid.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'accepted a paid runner in the offline test list'
printf 'PASS: CI-list runner preserves Python, runs every suite, and fails closed\n'
