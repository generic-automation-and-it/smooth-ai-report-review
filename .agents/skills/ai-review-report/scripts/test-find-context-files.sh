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
# No underscore, on purpose — this one must NOT be discovered. The convention
# is `*_AGENTS.md`, and the underscore is what keeps the exact standard
# `AGENTS.md` basename out of explicit context without needing a companion
# carve-out (find(1)'s leading `*` matches zero characters). Asserted negative
# below so a later widening to `*AGENTS.md` is caught here rather than by the
# duplicate-injection it would cause.
touch "$REPO/src/feature/FooAGENTS.md"
touch "$REPO/docs/AGENTS.md" "$REPO/docs/KEEP_AGENTS.md" "$REPO/docs/rules.txt"
touch "$REPO/.github/instructions/root.instructions.md"
touch "$REPO/.github/instructions/backend/nested.instructions.md"
touch "$REPO/.agents/rules/top.md" "$REPO/.agents/rules/backend/nested.md"
touch "$REPO/.agents/rules-scoped/backend/testing-standards.instructions.md"

(
  cd "$REPO"
  GITHUB_OUTPUT="$REPO/output" \
  MANDATORY_CONTEXT_FILES='AGENTS.md docs/AGENTS.md docs/KEEP_AGENTS.md docs/rules.txt' \
    bash "$FINDER" > "$REPO/run.log" 2>&1
)

for expected in \
  src/FEATURE_AGENTS.md \
  src/feature/LOCAL_AGENTS.md \
  docs/KEEP_AGENTS.md \
  docs/rules.txt \
  .github/instructions/root.instructions.md \
  .github/instructions/backend/nested.instructions.md \
  .agents/rules/top.md \
  .agents/rules/backend/nested.md; do
  grep -Fxq "$expected" "$REPO/ci_temp/context_files.txt" \
    || fail "expected context path missing: $expected"
done
ok "custom *_AGENTS.md, mandatory paths, and recursive .agents + GitHub rules are retained"

if grep -Eq '(^|/)AGENTS\.md$' "$REPO/ci_temp/context_files.txt"; then
  fail "standard AGENTS.md was duplicated into explicit chunk context"
fi
ok "exact AGENTS.md basenames are excluded for native v2 scope loading"

# The convention is the underscore, and it is what does the excluding above.
# A non-underscore name is deliberately out of scope: widening the pattern to
# `*AGENTS.md` to pick it up would also match the exact standard basename,
# because find(1)'s leading `*` matches zero characters — and v2 already loads
# every AGENTS.md natively, so that widening injects the same file twice.
if grep -q 'FooAGENTS\.md' "$REPO/ci_temp/context_files.txt"; then
  fail "a non-underscore AGENTS name was discovered — the pattern has been widened past the convention, which also re-admits the exact AGENTS.md basename"
fi
ok "non-underscore AGENTS names stay out of scope (the underscore is the exclusion)"

# On v2 nothing resolves the config's `instructions` array, so
# find-context-files.sh is the only thing that loads those files. The docs
# state that as a guarantee ("adding an entry without adding it here ships a
# rule file that silently never reaches the model"), so the test has to check
# the guarantee, not a hardcoded pair: a third tree added to the config must
# fail CI until the finder enumerates it too. Deriving the list from the config
# is the difference between testing the invariant and testing two examples.
CONFIG="$SCRIPT_DIR/../assets/opencode.json"
declared_roots="$(python3 - "$CONFIG" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
roots = []
for entry in cfg.get("instructions", []):
    if "://" in entry:            # URLs are not a filesystem tree
        continue
    head = entry.split("*", 1)[0].rstrip("/")   # prefix before the first glob
    if "/" in head and head not in roots:
        roots.append(head)
print("\n".join(roots))
PYEOF
)"
[ -n "$declared_roots" ] || fail "could not derive any instructions root from $CONFIG"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  grep -Fq "find ${root} -type f" "$FINDER" \
    || fail "opencode.json declares instructions under '${root}/' but find-context-files.sh never enumerates it — on v2 those files would be declared and never loaded"
done <<< "$declared_roots"
ok "every instructions root the config declares is enumerated by the finder ($(echo "$declared_roots" | tr '\n' ' ' | sed 's/ $//'))"

# The root check above is necessary but not sufficient: it collapses every
# pattern under a root to that root, so a NEW pattern under an existing root —
# `.github/instructions/*.md`, say — reads as covered while the finder still
# enumerates only `*.instructions.md` (review 5266192686, finding 2). So every
# declared glob is also tested BEHAVIOURALLY: a representative fixture is
# written for it (`*` → `probe`, `**` → `deep/x`), the finder is re-run, and
# the fixture must be discovered. A control pattern the finder does not
# enumerate must NOT be discovered, or this check is decoration.
CONFIG_PATTERNS="$(python3 - "$CONFIG" <<'PYEOF2'
import json, sys
cfg = json.load(open(sys.argv[1]))
for entry in cfg.get("instructions", []):
    if "://" in entry:
        continue
    print(entry)
PYEOF2
)"
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
# Control: declared nowhere, enumerated nowhere — must stay undiscovered.
CONTROL="$(_fixture_for '.github/instructions/*.md' control)"
mkdir -p "$PROBE_REPO/$(dirname "$CONTROL")"; touch "$PROBE_REPO/$CONTROL"
# The finder requires MANDATORY_CONTEXT_FILES to be set (absent paths warn and
# skip), and exits non-zero otherwise — under `set -e` that would end this
# script here with no assertion printed.
( cd "$PROBE_REPO" && GITHUB_OUTPUT="$PROBE_REPO/output" MANDATORY_CONTEXT_FILES='AGENTS.md' bash "$FINDER" > "$PROBE_REPO/run.log" 2>&1 ) \
  || fail "the finder exited non-zero in the probe repo: $(tail -3 "$PROBE_REPO/run.log" | tr '\n' ' ')"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -Fxq "$f" "$PROBE_REPO/ci_temp/context_files.txt" \
    || fail "opencode.json declares a pattern whose representative file '$f' the finder did not discover — on v2 that pattern is declared and never loaded"
done <<< "$_probe_paths"
if grep -Fxq "$CONTROL" "$PROBE_REPO/ci_temp/context_files.txt"; then
  fail "the control fixture '$CONTROL' was discovered although no declared pattern covers it — the behavioural check cannot discriminate"
fi
ok "every declared instructions glob discovers a representative file, and an undeclared sibling does not"

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
# discovered rule trees are untouched. Blank cannot express this — every layer
# above the finder turns blank into the built-in product-repo list.
run_finder() { # run_finder <value> — fresh ci_temp, log in $REPO/run.log, rc in $finder_rc
  find "$REPO/ci_temp" -mindepth 1 ! -name changed_files.txt -delete
  finder_rc=0
  ( cd "$REPO" && GITHUB_OUTPUT="$REPO/output" MANDATORY_CONTEXT_FILES="$1" \
      bash "$FINDER" > "$REPO/run.log" 2>&1 ) || finder_rc=$?
}
for _none in 'none' $'  NONE\n'; do
  run_finder "$_none"
  [ "$finder_rc" -eq 0 ] || fail "MANDATORY_CONTEXT_FILES='$_none' made the finder exit $finder_rc"
  if grep -q 'Mandatory context file not found' "$REPO/run.log"; then
    fail "MANDATORY_CONTEXT_FILES='$_none' was treated as a path and warned"
  fi
  grep -q 'declares no mandatory context files' "$REPO/run.log" \
    || fail "MANDATORY_CONTEXT_FILES='$_none' did not log the opt-out"
  [ ! -s "$REPO/ci_temp/mandatory_context_files.txt" ] \
    || fail "MANDATORY_CONTEXT_FILES='$_none' recorded mandatory paths"
  grep -Fxq '.agents/rules/top.md' "$REPO/ci_temp/context_files.txt" \
    || fail "MANDATORY_CONTEXT_FILES='$_none' also dropped discovered rule files"
done
ok "'none' (any case, surrounding whitespace) opts out of mandatory context without warnings"

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

# Unset still fails closed (LADR-025/029): the opt-out is explicit, never implied.
finder_rc=0
( cd "$REPO" && env -u MANDATORY_CONTEXT_FILES GITHUB_OUTPUT="$REPO/output" \
    bash "$FINDER" > "$REPO/run.log" 2>&1 ) || finder_rc=$?
[ "$finder_rc" -eq 2 ] || fail "unset MANDATORY_CONTEXT_FILES exited $finder_rc, expected 2"
ok "unset MANDATORY_CONTEXT_FILES still fails closed"

# `none` reaches the gate through the `mandatory_context_files` input, so the
# input must exist on BOTH entry points that accept inputs (workflow_call and
# workflow_dispatch) and feed the env var directly — input, else built-in list,
# with no Variable in between (the per-run input is the contract).
WORKFLOW="$SCRIPT_DIR/../../../../.github/workflows/pipeline-code-review-report.yml"
_mcf_expr="$(awk '/^ *MANDATORY_CONTEXT_FILES: >-/{f=1;next} f&&/}}/{print;exit} f{print}' "$WORKFLOW" | tr -s ' \n' ' ')"
case "$_mcf_expr" in
  *'inputs.mandatory_context_files || '\''.docs/'*) ;;
  *) fail "pipeline-code-review-report.yml does not map input → built-in list: $_mcf_expr" ;;
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
