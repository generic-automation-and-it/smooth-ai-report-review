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

# LADR-110: the analyse agent must not edit the tooling/scratch trees that the
# credential-bearing `Commit fixes` step later executes.
for path in '*.smooth-ai-review-tools/*' '*.context/*' '*ci_temp/*' '*.git/*' '*.env' '*.env.*'; do
  jq -e --arg p "$path" '.agent.analyse.permission.edit[$p] == "deny"' "$BUILTIN" >/dev/null \
    || fail "built-in analyse edit fence is missing $path"
done
echo "✅ analyse edit fence denies tooling, scratch, .git and .env paths"

missing="$(jq -r --slurpfile repo "$REPO_CONFIG" \
  '(.provider.openai.models | keys) - ($repo[0].provider.openai.models | keys) | .[]' "$BUILTIN")"
[ -z "$missing" ] || fail "$REPO_CONFIG_REL drops built-in openai models: $missing"
echo "✅ $REPO_CONFIG_REL declares every built-in openai model"

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

# LADR-131: one role contract is the behavioural definition, and both agent
# blocks in both config files implement it. WT-01 measured OpenCode matches
# `grep` patterns on the query rather than the path, so content search is
# denied rather than path-fenced, and `/proc/**` is a real read deny.
CONTRACT="$REPO_ROOT/.agents/skills/ai-review-report/assets/role-contract.json"
[ -f "$CONTRACT" ] || fail "role contract is missing"
jq empty "$CONTRACT" || fail "role contract is not valid JSON"
jq -e '.contentSearch == "deny"' "$CONTRACT" >/dev/null \
  || fail "role contract does not record the content-search verdict"
for role in review analyse; do
  jq -e --arg r "$role" '.roles[$r].allowedTools and .roles[$r].deniedTools and .roles[$r].read and .roles[$r].edit' "$CONTRACT" >/dev/null \
    || fail "role contract is incomplete for $role"
  jq -e --arg r "$role" '.roles[$r].read.allowPaths | index(".env.example") != null' "$CONTRACT" >/dev/null \
    || fail "role contract does not keep .env.example readable for $role"
done
for deny in '.env' '.env.*' '.git' '.git/**' '/proc/*' '/proc/**'; do
  jq -e --arg d "$deny" '.roles.review.read.denyPaths | index($d) != null' "$CONTRACT" >/dev/null \
    || fail "role contract does not deny review read on $deny"
  jq -e --arg d "$deny" '.roles.analyse.read.denyPaths | index($d) != null' "$CONTRACT" >/dev/null \
    || fail "role contract does not deny analyse read on $deny"
done
echo "✅ role contract lists both roles and their denied path classes"

for cfg in "$BUILTIN" "$REPO_CONFIG"; do
  for role in review analyse; do
    jq -e --arg r "$role" '.agent[$r].permission.read["*"] == "allow"' "$cfg" >/dev/null \
      || fail "$(basename "$cfg") $role read default is not allow"
    for deny in '*.env' '*.env.*' '*.git' '*.git/*' '/proc/*' '/proc/**'; do
      jq -e --arg r "$role" --arg d "$deny" '.agent[$r].permission.read[$d] == "deny"' "$cfg" >/dev/null \
        || fail "$(basename "$cfg") $role read does not deny $deny"
    done
    jq -e --arg r "$role" '.agent[$r].permission.read["*.env.example"] == "allow"' "$cfg" >/dev/null \
      || fail "$(basename "$cfg") $role read does not keep .env.example readable"
    jq -e --arg r "$role" '.agent[$r].permission.grep == "deny"' "$cfg" >/dev/null \
      || fail "$(basename "$cfg") $role content search is not denied"
  done
  jq -e '.agent.review.permission.edit == "deny"' "$cfg" >/dev/null \
    || fail "$(basename "$cfg") review edit is not denied"
  for tool in bash webfetch websearch execute; do
    jq -e --arg t "$tool" '.agent.review.permission[$t] == "deny"' "$cfg" >/dev/null \
      || fail "$(basename "$cfg") review $tool is not denied"
    jq -e --arg t "$tool" '.agent.analyse.permission[$t] == "deny"' "$cfg" >/dev/null \
      || fail "$(basename "$cfg") analyse $tool is not denied"
  done
done
echo "✅ both config files implement the role contract's read and content-search denials"


# LADR-123: OpenCode evaluates permission patterns in order, last match wins
# (WT-01 M5). A deny entry that exists but sits before a wildcard allow is
# ineffective, so assert the EFFECTIVE value for representative paths.
_read_perm() { # _read_perm <cfg> <role> <path>
  local cfg="$1" role="$2" p="$3" pat val out=""
  while IFS=$'\t' read -r pat val; do
    case "$p" in $pat) out="$val" ;; esac
  done < <(jq -r --arg r "$role" \
    '.agent[$r].permission.read | to_entries[] | "\(.key)\t\(.value)"' "$cfg")
  printf '%s' "$out"
}
for cfg in "$BUILTIN" "$REPO_CONFIG"; do
  for role in review analyse; do
    for p in '.env' '.env.production' '.git/config' '.git/HEAD' '/proc/self/environ'; do
      [ "$(_read_perm "$cfg" "$role" "$p")" = "deny" ] \
        || fail "$(basename "$cfg") $role effective read on $p is not deny"
    done
    [ "$(_read_perm "$cfg" "$role" '.env.example')" = "allow" ] \
      || fail "$(basename "$cfg") $role effective read on .env.example is not allow"
  done
done
# Negative control: moving the wildcard allow last must make .env readable, so
# this checker would catch that regression. If it still reports deny, the check
# is not order-sensitive and the assertion above proves nothing.
_bad_cfg="$(mktemp)"
jq '.agent.review.permission.read |= (del(."*") + {"*": "allow"})' "$BUILTIN" > "$_bad_cfg"
[ "$(_read_perm "$_bad_cfg" review '.env')" = "allow" ] \
  || fail "effective read check is not order-sensitive (wildcard-last fixture still reports deny)"
rm -f "$_bad_cfg"
echo "✅ effective read permissions deny protected paths and keep .env.example readable"

# LADR-131: conformance is derived from the contract, so a contract change that
# the config does not follow fails here instead of passing on static values.
for cfg in "$BUILTIN" "$REPO_CONFIG"; do
  for role in review analyse; do
    while IFS= read -r tool; do
      [ -n "$tool" ] || continue
      jq -e --arg r "$role" --arg t "$tool"         '.agent[$r].tools[$t] != false and (.agent[$r].permission[$t] // "allow") != "deny"' "$cfg" >/dev/null \
        || fail "$(basename "$cfg") $role does not implement allowed tool $tool"
    done < <(jq -r --arg r "$role" '.roles[$r].allowedTools[]' "$CONTRACT")
    while IFS= read -r tool; do
      [ -n "$tool" ] || continue
      jq -e --arg r "$role" --arg t "$tool"         '.agent[$r].tools[$t] == false or (.agent[$r].permission[$t] // "") == "deny"' "$cfg" >/dev/null \
        || fail "$(basename "$cfg") $role does not implement denied tool $tool"
    done < <(jq -r --arg r "$role" '.roles[$r].deniedTools[]' "$CONTRACT")
    while IFS= read -r pathspec; do
      [ -n "$pathspec" ] || continue
      case "$pathspec" in
        '.env') sample='.env' ;;
        '.env.*') sample='.env.production' ;;
        '.git') sample='.git' ;;
        '.git/**'|'.git/*') sample='.git/config' ;;
        '/proc/*'|'/proc/**') sample='/proc/self/environ' ;;
        *) sample="${pathspec//\*\*/x}" ;;
      esac
      [ "$(_read_perm "$cfg" "$role" "$sample")" = "deny" ] \
        || fail "$(basename "$cfg") $role does not effectively deny contract read path $pathspec (sample $sample)"
    done < <(jq -r --arg r "$role" '.roles[$r].read.denyPaths[]' "$CONTRACT")
  done
done
echo "✅ conformance is derived from the role contract, not a static value list"

# The edit fence is checked the same way: effective permission for a sample
# path, with the ordered wildcard-last case as a negative control.
_edit_perm() { # _edit_perm <cfg> <role> <path>
  local cfg="$1" role="$2" p="$3" pat val out=""
  if jq -e --arg r "$role" '.agent[$r].permission.edit | type == "string"' "$cfg" >/dev/null 2>&1; then
    jq -r --arg r "$role" '.agent[$r].permission.edit' "$cfg"
    return
  fi
  while IFS=$'\t' read -r pat val; do
    case "$p" in $pat) out="$val" ;; esac
  done < <(jq -r --arg r "$role" \
    '.agent[$r].permission.edit | to_entries[] | "\(.key)\t\(.value)"' "$cfg" 2>/dev/null)
  printf '%s' "$out"
}
while IFS= read -r pathspec; do
  [ -n "$pathspec" ] || continue
  case "$pathspec" in
    '.smooth-ai-review-tools/**'|'.smooth-ai-review-tools/*') sample='.smooth-ai-review-tools/x.sh' ;;
    '.context/**'|'.context/*') sample='.context/x.json' ;;
    'ci_temp/**'|'ci_temp/*'|'*ci_temp/*') sample='ci_temp/x.txt' ;;
    '.git/**'|'.git/*') sample='.git/config' ;;
    '.env') sample='.env' ;;
    '.env.*') sample='.env.production' ;;
    *) sample="${pathspec//\*\*/x}" ;;
  esac
  [ "$(_edit_perm "$BUILTIN" analyse "$sample")" = "deny" ] \
    || fail "built-in analyse does not effectively deny edit on $pathspec (sample $sample)"
  [ "$(_edit_perm "$REPO_CONFIG" analyse "$sample")" = "deny" ] \
    || fail "$REPO_CONFIG_REL analyse does not effectively deny edit on $pathspec (sample $sample)"
done < <(jq -r '.roles.analyse.edit.denyPaths[]' "$CONTRACT")
check_edit_allow='.env.example'
[ "$(_edit_perm "$BUILTIN" analyse "$check_edit_allow")" = "allow" ] \
  || fail "built-in analyse does not keep $check_edit_allow editable"
[ "$(_edit_perm "$BUILTIN" review '.context/x.json')" = "deny" ] \
  || fail "built-in review edit is not denied outright"
bad_edit="$(mktemp)"
jq '.agent.analyse.permission.edit |= (del(."*") + {"*": "allow"})' "$BUILTIN" > "$bad_edit"
[ "$(_edit_perm "$bad_edit" analyse '.context/x.json')" = "allow" ] \
  || fail "effective edit check is not order-sensitive (wildcard-last fixture still reports deny)"
rm -f "$bad_edit"
echo "✅ effective edit permissions deny protected paths and keep .env.example editable"
