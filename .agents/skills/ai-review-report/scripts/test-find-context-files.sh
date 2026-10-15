#!/bin/bash
# Offline regression tests for OpenCode v2 context discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINDER="$SCRIPT_DIR/find-context-files.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

fail() { echo "❌ $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "✅ $*"; }

mkdir -p "$REPO/ci_temp" "$REPO/src/feature" "$REPO/.github/instructions/backend" "$REPO/docs" \
  "$REPO/.agents/rules/backend" "$REPO/.agents/rules-scoped/backend"
printf 'src/feature/app.ts\0' > "$REPO/ci_temp/changed_files.txt"
touch "$REPO/AGENTS.md" "$REPO/src/AGENTS.md" "$REPO/src/feature/AGENTS.md"
touch "$REPO/src/FEATURE_AGENTS.md" "$REPO/src/feature/LOCAL_AGENTS.md"
# Neither standard nor custom AGENTS-like names are auto-discovered by this
# channel. Explicitly opted-in custom paths are tested separately below.
touch "$REPO/src/feature/FooAGENTS.md"
touch "$REPO/docs/AGENTS.md" "$REPO/docs/KEEP_AGENTS.md" "$REPO/docs/rules.txt"
# LADR-104: `*instructions.scoped.md` is the injected opt-in; a plain
# `*.instructions.md` file is documentation and must NOT be discovered.
touch "$REPO/.github/instructions/root.instructions.scoped.md"
touch "$REPO/.github/instructions/backend/nested.instructions.scoped.md"
touch "$REPO/.github/instructions/reference.instructions.md"
# Plain markdown in the same directory is documentation too: the finder injects
# the scoped name only, so `notes.md` must not appear either.
touch "$REPO/.github/instructions/notes.md"
touch "$REPO/.agents/rules/top.md" "$REPO/.agents/rules/backend/nested.md"
# Legacy rules remain declared in opencode.json, but the custom loader must
# not inject them automatically (LADR-105). They can still be opted in below.
touch "$REPO/.agents/rules/legacy.instructions.md"
touch "$REPO/.agents/rules-scoped/backend/testing-standards.instructions.md"

(
  cd "$REPO"
  GITHUB_OUTPUT="$REPO/output" \
  MANDATORY_CONTEXT_FILES='AGENTS.md docs/AGENTS.md docs/KEEP_AGENTS.md docs/rules.txt' \
    bash "$FINDER" > "$REPO/run.log" 2>&1
)

for expected in \
  docs/KEEP_AGENTS.md \
  docs/rules.txt \
  .github/instructions/root.instructions.scoped.md \
  .github/instructions/backend/nested.instructions.scoped.md; do
  grep -Fxq "$expected" "$REPO/ci_temp/context_files.txt" \
    || fail "expected context path missing: $expected"
done
ok "explicit mandatory paths and recursive scoped instruction discovery are retained"

# LADR-104: the name is the opt-in. An unscoped `*.instructions.md` sibling must
# stay out of the injected set even though it sits in the very directory the
# finder traverses — otherwise the convention is decorative.
for _doc in .github/instructions/reference.instructions.md .github/instructions/notes.md \
    .agents/rules/top.md .agents/rules/backend/nested.md .agents/rules/legacy.instructions.md \
    src/FEATURE_AGENTS.md src/feature/LOCAL_AGENTS.md src/feature/FooAGENTS.md; do
  grep -Fxq "$_doc" "$REPO/ci_temp/context_files.txt" \
    && fail "$_doc was injected — only *instructions.scoped.md opts in (LADR-104)"
done
ok "custom discovery injects only scoped instruction files, not legacy rules or custom *_AGENTS.md"

if grep -Eq '(^|/)AGENTS\.md$' "$REPO/ci_temp/context_files.txt"; then
  fail "standard AGENTS.md was duplicated into explicit chunk context"
fi
ok "exact AGENTS.md basenames are excluded for native v2 scope loading"

# Keep config unchanged: custom discovery materializes only its scoped
# instruction patterns, not the declarative .agents/rules/*.md entries.
# Derive fixtures from the scoped declarations so their coverage stays pinned.
CONFIG="$SCRIPT_DIR/../assets/opencode.json"
# Every scoped declaration is tested BEHAVIOURALLY: a
# representative fixture is written for it (`*` → `probe`, `**` → `deep/x`), the
# finder is re-run, and the fixture must be discovered. A control pattern the
# finder does not enumerate must NOT be discovered, or this check is decoration.
CONFIG_PATTERNS="$(python3 - "$CONFIG" <<'PYEOF2'
import json, sys
cfg = json.load(open(sys.argv[1]))
for entry in cfg.get("instructions", []):
    if "://" in entry or not entry.endswith(".instructions.scoped.md"):
        continue
    print(entry)
PYEOF2
)"
[ -n "$CONFIG_PATTERNS" ] || fail "no scoped instruction declarations found in $CONFIG"
_fixture_for() { # _fixture_for <glob> <stem>  → a concrete path matching the glob
  python3 - "$1" "$2" <<'PYEOF3'
import sys
pat, stem = sys.argv[1], sys.argv[2]
out = pat.replace("**", "deep/x")
head, star, tail = out.partition("*")
print(head + stem + tail if star else out)
PYEOF3
}
PROBE_REPO="$TMP/probe-repo"; mkdir -p "$PROBE_REPO/ci_temp"
printf 'src/app.ts\0' > "$PROBE_REPO/ci_temp/changed_files.txt"
_probe_paths=""
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  f="$(_fixture_for "$pat" probe)"
  mkdir -p "$PROBE_REPO/$(dirname "$f")"; touch "$PROBE_REPO/$f"
  _probe_paths="${_probe_paths}${f}
"
done <<< "$CONFIG_PATTERNS"
# Control: `.agents/rules-scoped/**` is declared in no glob and enumerated by no
# find (it reaches a review only through MANDATORY_CONTEXT_FILES), so the probe
# must find nothing there — otherwise the loop would pass with a finder that
# matched everything. The `.github/instructions` negative above covers the old
# name specifically; this one proves the loop can discriminate at all.
CONTROL="$(_fixture_for '.agents/rules-scoped/**/*.md' control)"
mkdir -p "$PROBE_REPO/$(dirname "$CONTROL")"; touch "$PROBE_REPO/$CONTROL"
( cd "$PROBE_REPO" && env -u MANDATORY_CONTEXT_FILES GITHUB_OUTPUT="$PROBE_REPO/output" bash "$FINDER" > "$PROBE_REPO/run.log" 2>&1 ) \
  || fail "the finder exited non-zero in the probe repo: $(tail -3 "$PROBE_REPO/run.log" | tr '\n' ' ')"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -Fxq "$f" "$PROBE_REPO/ci_temp/context_files.txt" \
    || fail "opencode.json declares a pattern whose representative file '$f' the finder did not discover — on v2 that pattern is declared and never loaded"
done <<< "$_probe_paths"
if grep -Fxq "$CONTROL" "$PROBE_REPO/ci_temp/context_files.txt"; then
  fail "the control fixture '$CONTROL' was discovered although no declared pattern covers it — the behavioural check cannot discriminate"
fi
ok "every declared scoped instructions glob discovers a representative file, and an undeclared sibling does not"

# Scoped rules are excluded on purpose: they reach a review through
# MANDATORY_CONTEXT_FILES, which the consuming repo controls per-run. Pulling
# the whole tree into every chunk would duplicate them and inflate prompts for
# chunks the scope does not cover.
if grep -q 'rules-scoped' "$REPO/ci_temp/context_files.txt"; then
  fail "the scoped rules tree was pulled into explicit context"
fi
if grep -Fq 'rules-scoped' "$CONFIG"; then
  fail "the config re-declared .agents/rules-scoped in instructions"
fi
ok ".agents/rules-scoped stays out of both the config and the explicit context"

# `none` as the whole value is an explicit "no mandatory context files"
# declaration: no per-path warnings, nothing recorded as mandatory, and the
# scoped discovery is untouched. Blank now defaults to none too.
run_finder() { # run_finder <value> — fresh ci_temp, log in $REPO/run.log, rc in $finder_rc
  find "$REPO/ci_temp" -mindepth 1 ! -name changed_files.txt -delete
  finder_rc=0
  ( cd "$REPO" && GITHUB_OUTPUT="$REPO/output" MANDATORY_CONTEXT_FILES="$1" \
      bash "$FINDER" > "$REPO/run.log" 2>&1 ) || finder_rc=$?
}
for _none in 'none' $'  NONE\n' ''; do
  run_finder "$_none"
  [ "$finder_rc" -eq 0 ] || fail "MANDATORY_CONTEXT_FILES='$_none' made the finder exit $finder_rc"
  if grep -q 'Mandatory context file not found' "$REPO/run.log"; then
    fail "MANDATORY_CONTEXT_FILES='$_none' was treated as a path and warned"
  fi
  grep -q 'declares no mandatory context files' "$REPO/run.log" \
    || fail "MANDATORY_CONTEXT_FILES='$_none' did not log the opt-out"
  [ ! -s "$REPO/ci_temp/mandatory_context_files.txt" ] \
    || fail "MANDATORY_CONTEXT_FILES='$_none' recorded mandatory paths"
  grep -Fxq '.github/instructions/root.instructions.scoped.md' "$REPO/ci_temp/context_files.txt" \
    || fail "MANDATORY_CONTEXT_FILES='$_none' also dropped discovered rule files"
  if grep -q 'Adding .*mandatory context files' "$REPO/run.log"; then
    fail "MANDATORY_CONTEXT_FILES='$_none' still announces mandatory loading"
  fi
done
ok "blank and 'none' keep scoped discovery without mandatory loading or warnings"

# Legacy paths remain available only through an explicit non-empty override.
run_finder '.agents/rules/legacy.instructions.md src/FEATURE_AGENTS.md'
for _explicit in .agents/rules/legacy.instructions.md src/FEATURE_AGENTS.md; do
  grep -Fxq "$_explicit" "$REPO/ci_temp/mandatory_context_files.txt" \
    || fail "explicit mandatory override missing: $_explicit"
done
ok "explicit non-empty mandatory lists still opt in legacy paths"

# Only the WHOLE value opts out: mixed with real paths, `none` is just a
# missing path, so a typo cannot silently discard the rest of the list.
run_finder 'none docs/rules.txt'
[ "$finder_rc" -eq 0 ] || fail "a list containing 'none' made the finder exit $finder_rc"
grep -q 'Mandatory context file not found: none' "$REPO/run.log" \
  || fail "'none' inside a list was not treated as an ordinary (missing) path"
grep -Fxq 'docs/rules.txt' "$REPO/ci_temp/mandatory_context_files.txt" \
  || fail "'none' inside a list discarded the real paths next to it"
ok "'none' only opts out as the whole value"

# The predicate itself, directly: the finder and local-review.sh both source
# this one definition, so these cases bind both call sites at once.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/mandatory-context.sh"
for _yes in 'none' 'NONE' 'None' '  none  ' $'\n\tnone\n'; do
  mandatory_context_is_none "$_yes" || fail "mandatory_context_is_none rejected $(printf '%q' "$_yes")"
done
for _no in '' ' ' 'no ne' 'none docs/a.md' 'docs/none' 'nones' $'none\nx'; do
  if mandatory_context_is_none "$_no"; then fail "mandatory_context_is_none accepted $(printf '%q' "$_no")"; fi
done
grep -q 'lib/mandatory-context.sh' "$SCRIPT_DIR/local-review.sh" \
  || fail "local-review.sh no longer uses the shared opt-out predicate"
grep -q 'lib/mandatory-context.sh' "$FINDER" \
  || fail "find-context-files.sh no longer uses the shared opt-out predicate"
ok "one opt-out predicate: whole-value 'none' only, shared by the finder and local-review.sh"

# Standalone discovery defaults to none too, without legacy-path warnings.
finder_rc=0
( cd "$REPO" && env -u MANDATORY_CONTEXT_FILES GITHUB_OUTPUT="$REPO/output" \
    bash "$FINDER" > "$REPO/run.log" 2>&1 ) || finder_rc=$?
[ "$finder_rc" -eq 0 ] || fail "unset MANDATORY_CONTEXT_FILES exited $finder_rc, expected 0"
[ ! -s "$REPO/ci_temp/mandatory_context_files.txt" ] || fail "unset default recorded mandatory paths"
if grep -q 'Mandatory context file not found' "$REPO/run.log"; then
  fail "unset default warned about legacy paths"
fi
ok "unset MANDATORY_CONTEXT_FILES defaults to none"

# With no scoped instructions, native/config/legacy files must not synthesize
# any custom context. Explicitly opting in a path is the only exception.
EMPTY_REPO="$TMP/no-scoped-repo"
mkdir -p "$EMPTY_REPO/ci_temp" "$EMPTY_REPO/.agents/rules" "$EMPTY_REPO/src"
printf 'src/app.ts\0' > "$EMPTY_REPO/ci_temp/changed_files.txt"
touch "$EMPTY_REPO/AGENTS.md" "$EMPTY_REPO/src/FEATURE_AGENTS.md" "$EMPTY_REPO/.agents/rules/legacy.instructions.md"
( cd "$EMPTY_REPO" && env -u MANDATORY_CONTEXT_FILES GITHUB_OUTPUT="$EMPTY_REPO/output" \
    bash "$FINDER" > "$EMPTY_REPO/run.log" 2>&1 )
grep -Fxq 'context_file_count=0' "$EMPTY_REPO/output" || fail "legacy files synthesized custom context"
[ ! -s "$EMPTY_REPO/ci_temp/mandatory_context_files.txt" ] || fail "default-none recorded mandatory context"
ok "no scoped files means no custom context, despite native/config/legacy files"

# Exercise the real default assignment from both script entrypoints, without
# running their model/install/git side effects or reproducing their defaults.
for entrypoint in run-review.sh local-review.sh; do
  assignment="$(grep '^MANDATORY_CONTEXT_FILES=' "$SCRIPT_DIR/$entrypoint")"
  [ -n "$assignment" ] || fail "$entrypoint has no mandatory default assignment"
  for value in unset blank explicit; do
    case "$value" in
      unset) prefix='unset MANDATORY_CONTEXT_FILES'; expected=none ;;
      blank) prefix='MANDATORY_CONTEXT_FILES=""'; expected=none ;;
      explicit) prefix='MANDATORY_CONTEXT_FILES="docs/rules.txt"'; expected=docs/rules.txt ;;
    esac
    actual="$(bash -c "$prefix; $assignment; printf '%s' \"\$MANDATORY_CONTEXT_FILES\"")"
    [ "$actual" = "$expected" ] || fail "$entrypoint $value resolved '$actual', expected '$expected'"
  done
done
ok "both script entrypoints default unset/blank to none and preserve explicit lists"

# `none` reaches the gate through the `mandatory_context_files` input, so the
# input must exist on BOTH entry points that accept inputs (workflow_call and
# workflow_dispatch) and feed the env var directly — input, else none,
# with no Variable in between (the per-run input is the contract).
WORKFLOW="$SCRIPT_DIR/../../../../.github/workflows/pipeline-code-review-report.yml"
_mcf_expr="$(grep '^[[:space:]]*MANDATORY_CONTEXT_FILES:' "$WORKFLOW")"
case "$_mcf_expr" in
  *'inputs.mandatory_context_files || '\''none'\'' }}'*) ;;
  *) fail "pipeline-code-review-report.yml does not map input → none: $_mcf_expr" ;;
esac
case "$_mcf_expr" in
  *vars.*) fail "pipeline-code-review-report.yml reads a Variable for MANDATORY_CONTEXT_FILES: $_mcf_expr" ;;
esac
for _trigger in workflow_dispatch workflow_call; do
  # Captured, not piped into `grep -q`: an early grep exit SIGPIPEs awk and
  # pipefail would report a present input as missing.
  _block="$(awk -v t="  ${_trigger}:" '$0==t{f=1;next} f&&/^  [a-z_]+:$/{exit} f' "$WORKFLOW")"
  case "$_block" in
    *$'\n      mandatory_context_files:\n'*) ;;
    *) fail "pipeline-code-review-report.yml: ${_trigger} does not declare the mandatory_context_files input" ;;
  esac
done
ok "mandatory_context_files is an input on workflow_dispatch and workflow_call, mapped straight to the env var"

echo "All $pass find-context-files tests passed"
