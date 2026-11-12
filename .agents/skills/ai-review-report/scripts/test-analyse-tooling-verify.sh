#!/bin/bash
# Offline regression test for the analyse workflow's "Verify pinned tooling is
# unmodified" step (LADR-110): the step's real shell body is extracted from the
# YAML and executed against clean and dirty tooling trees in both modes.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$REPO_ROOT/.github/workflows/pipeline-ai-analyse.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "❌ $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
python3 -c 'import yaml' 2>/dev/null || fail "PyYAML is required (scripts/requirements-test.txt)"

python3 - "$WF" "$TMP/verify.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name") == "Verify pinned tooling is unmodified":
            open(sys.argv[2], "w").write(step["run"])
            sys.exit(0)
raise SystemExit("verify step not found")
PY

make_repo() {
  mkdir -p "$1"
  (
    cd "$1"
    git init -q
    git config user.email t@t
    git config user.name t
    mkdir -p .agents/skills/ai-review-report/lib .agents/skills/ai-analyse .agents/skills/ai-review
    echo a > .agents/skills/ai-review-report/lib/x.sh
    git add -A
    git commit -qm init
  )
}

expect_rc() {
  local name="$1" want="$2" dir="$3" rsd="$4"
  set +e
  ( cd "$dir" && REVIEW_SKILL_DIR="$rsd" \
      ANALYSE_SKILL_DIR=.agents/skills/ai-analyse \
      AI_REVIEW_DIR=.agents/skills/ai-review \
      bash "$TMP/verify.sh" ) >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq "$want" ] || fail "$name: expected exit ${want}, got ${rc}"
  echo "  ✅ $name"
}

# Fetched tooling tree.
make_repo "$TMP/fetched"
git clone -q "$TMP/fetched" "$TMP/fetched/.smooth-ai-review-tools"
RSD=".smooth-ai-review-tools/.agents/skills/ai-review-report"
expect_rc "fetched tooling clean passes" 0 "$TMP/fetched" "$RSD"
echo b >> "$TMP/fetched/.smooth-ai-review-tools/.agents/skills/ai-review-report/lib/x.sh"
expect_rc "fetched tooling edit blocks" 1 "$TMP/fetched" "$RSD"

# In-repo tooling tree.
make_repo "$TMP/inrepo"
RSD=".agents/skills/ai-review-report"
expect_rc "in-repo tooling clean passes" 0 "$TMP/inrepo" "$RSD"
echo b >> "$TMP/inrepo/.agents/skills/ai-review-report/lib/x.sh"
expect_rc "in-repo tooling edit blocks" 1 "$TMP/inrepo" "$RSD"
git -C "$TMP/inrepo" checkout -q -- .agents/skills/ai-review-report/lib/x.sh
echo evil > "$TMP/inrepo/.agents/skills/ai-review-report/lib/evil.sh"
expect_rc "in-repo untracked tooling file blocks" 1 "$TMP/inrepo" "$RSD"

echo "✅ analyse tooling verify step blocks edits in both tooling modes"
