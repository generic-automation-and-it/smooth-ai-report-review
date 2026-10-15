#!/bin/bash
# Offline regression test for this repo's own custom opencode.json (LADR-047).
#
# `.github/opencode.json` is the config this repo's gate loads through the
# OPENCODE_REVIEW_REPORT_CONFIG Variable. It carries the model ids only this
# repo's gateway serves, so the shared built-in `assets/opencode.json` — the
# default every consumer gets — stays free of them. An LADR-047 override
# REPLACES the built-in rather than merging over it, so the copy must track
# everything else in the built-in: agents and their permissions (LADR-029/094),
# the `instructions` list (LADR-087) and every other provider. This test pins
# that: the two files may differ only in `provider.openai.models`, and the copy
# must still declare every built-in openai model. Both the gate and ai-analyse
# must forward OPENCODE_REVIEW_REPORT_CONFIG, or one of them silently runs on the
# built-in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BUILTIN="$REPO_ROOT/.agents/skills/ai-review-report/assets/opencode.json"
REPO_CONFIG_REL=".github/opencode.json"
REPO_CONFIG="$REPO_ROOT/$REPO_CONFIG_REL"
LIB="$SCRIPT_DIR/lib/prepare-opencode-config.sh"

fail() { echo "❌ $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$REPO_CONFIG" ] || fail "$REPO_CONFIG_REL is missing"
jq empty "$REPO_CONFIG" || fail "$REPO_CONFIG_REL is not valid JSON"

if ! diff <(jq -S 'del(.provider.openai.models)' "$BUILTIN") \
          <(jq -S 'del(.provider.openai.models)' "$REPO_CONFIG") >/dev/null; then
  diff <(jq -S 'del(.provider.openai.models)' "$BUILTIN") \
       <(jq -S 'del(.provider.openai.models)' "$REPO_CONFIG") >&2 || true
  fail "$REPO_CONFIG_REL differs from the built-in outside provider.openai.models — copy the change across"
fi
echo "✅ $REPO_CONFIG_REL matches the built-in outside provider.openai.models"

missing="$(jq -r --slurpfile repo "$REPO_CONFIG" \
  '(.provider.openai.models | keys) - ($repo[0].provider.openai.models | keys) | .[]' "$BUILTIN")"
[ -z "$missing" ] || fail "$REPO_CONFIG_REL drops built-in openai models: $missing"
echo "✅ $REPO_CONFIG_REL declares every built-in openai model"

# A third copy exists for local sessions: `.agents/opencode.json`, root-symlinked
# as `opencode.json` so a session in this repo resolves a project config the way
# `.claude` / `.codex` resolve `.agents`. Nothing else covers it — test-repo-opencode-config.sh
# compared two files, and a third silent copy is exactly the drift LADR-087
# warns about ("add to one and you must add to the other"). It carries ONLY the
# `instructions` globs, so pin those and nothing else.
LOCAL_CONFIG_REL=".agents/opencode.json"
LOCAL_CONFIG="$REPO_ROOT/$LOCAL_CONFIG_REL"
[ -f "$LOCAL_CONFIG" ] || fail "$LOCAL_CONFIG_REL is missing"
[ -L "$REPO_ROOT/opencode.json" ] || fail "root opencode.json must stay a symlink to $LOCAL_CONFIG_REL"
[ "$(readlink "$REPO_ROOT/opencode.json")" = "$LOCAL_CONFIG_REL" ] \
  || fail "root opencode.json points somewhere other than $LOCAL_CONFIG_REL"
_extra_keys="$(jq -r 'keys - ["$schema", "instructions"] | join(",")' "$LOCAL_CONFIG")"
[ -z "$_extra_keys" ] || fail "$LOCAL_CONFIG_REL may declare only \$schema and instructions (also: $_extra_keys)"
diff <(jq -S '.instructions' "$BUILTIN") <(jq -S '.instructions' "$LOCAL_CONFIG") >/dev/null \
  || fail "$LOCAL_CONFIG_REL instructions differ from the built-in — copy the globs across"
echo "✅ $LOCAL_CONFIG_REL (root symlinked) carries the built-in instructions globs and nothing else"

# The override must resolve through the real lib and still receive the
# gateway URL injection (the URL is a Variable, never committed).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/ci_temp" "$TMP/repo/.github" "$TMP/home"
cp "$REPO_CONFIG" "$TMP/repo/$REPO_CONFIG_REL"
(
  cd "$TMP/repo"
  # GITHUB_ENV cleared so the lib does not export a temp path to later steps.
  HOME="$TMP/home" GITHUB_WORKSPACE="$TMP/repo" GITHUB_ENV= \
    OPENCODE_REVIEW_REPORT_CONFIG="$REPO_CONFIG_REL" \
    OPENCODE_REVIEW_REPORT_OPENAI_URL=https://gateway.example/v1 \
    bash -c '. "'"$LIB"'"; jq -e '\''.provider.openai.options.baseURL == "https://gateway.example/v1"'\'' "$OPENCODE_CONFIG"' \
    > "$TMP/run.out" 2>&1
) || { cat "$TMP/run.out" >&2; fail "$REPO_CONFIG_REL did not resolve through prepare-opencode-config.sh"; }
echo "✅ $REPO_CONFIG_REL resolves as an OPENCODE_REVIEW_REPORT_CONFIG override and receives the gateway URL"

# Both consumers of the config must read the override, or one of them silently
# keeps running on the built-in.
for wf in pipeline-code-review-report.yml pipeline-ai-analyse.yml; do
  grep -Eq '^ +OPENCODE_REVIEW_REPORT_CONFIG: \$\{\{.*vars\.OPENCODE_REVIEW_REPORT_CONFIG' \
    "$REPO_ROOT/.github/workflows/$wf" \
    || fail "$wf does not forward OPENCODE_REVIEW_REPORT_CONFIG"
done
echo "✅ the gate and ai-analyse both forward OPENCODE_REVIEW_REPORT_CONFIG"
