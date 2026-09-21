#!/bin/bash
set -e

# Test script for the per-chunk context scope filter:
#   lib/filter-context-scope.sh  — interpreter resolution + fail-open wrapper
#   lib/context-scope-filter.py  — frontmatter parsing and glob matching
#
# Offline: no model calls, no network.
#
# The filter decides which rule files reach a chunk prompt, so both directions
# of error matter, and they are NOT symmetric: including a rule the chunk did
# not need costs a path in a list, while dropping one it did need changes review
# output with no signal at all. Every uncertain case must therefore resolve
# toward inclusion, and these tests pin that as hard as they pin the matching.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_SH="$SCRIPT_DIR/lib/filter-context-scope.sh"
FILTER_PY="$SCRIPT_DIR/lib/context-scope-filter.py"

TMP_DIR="$(mktemp -d)"
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$TMP_DIR"; if [ "$SUITE_COMPLETED" != "1" ]; then echo ""; echo "❌ SUITE ABORTED EARLY (exit $rc) — assertions after this point never ran"; fi' EXIT

echo "=========================================="
echo "Testing context scope filter"
echo "=========================================="
echo ""

pass=0
fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"; pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---";   printf '%s\n' "$actual"
    fail=$((fail + 1))
  fi
}

if [ ! -f "$FILTER_SH" ] || [ ! -f "$FILTER_PY" ]; then
  echo "⏭️  scope filter scripts missing — skipping"
  SUITE_COMPLETED=1
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo "⏭️  no Python interpreter — the filter is a soft dependency, skipping"
  SUITE_COMPLETED=1
  exit 0
fi

R="$TMP_DIR/rules"
mkdir -p "$R"
rule() { # rule <name> <applyTo-or-empty> [extra-frontmatter-line]
  local f="$R/$1.md"
  {
    echo "---"
    [ -n "${2:-}" ] && echo "applyTo: '$2'"
    [ -n "${3:-}" ] && echo "$3"
    echo "---"
    echo "body of $1"
  } > "$f"
  echo "$f"
}
run() { # run <chunk-file-list-string> <candidate-paths...>
  local chunk="$1"; shift
  printf '%s\n' $chunk > "$TMP_DIR/chunk.txt"
  printf '%s\n' "$@" > "$TMP_DIR/cands.txt"
  bash "$FILTER_SH" "$TMP_DIR/chunk.txt" "$TMP_DIR/cands.txt" 2>/dev/null | sed "s|^$R/||" | tr '\n' ' ' | sed 's/ $//'
}

# --- Matching basics -------------------------------------------------------
BACKEND="$(rule backend 'src/**/*.cs')"
DOCS="$(rule docs 'docs/**/*.md')"
ALL="$(rule all '**')"
check "Test 1: a rule whose applyTo excludes every chunk file is dropped" "docs.md all.md" \
  "$(run 'docs/wiki/ci.md' "$BACKEND" "$DOCS" "$ALL")"
check "Test 2: a rule matching a chunk file is kept" "backend.md" \
  "$(run 'src/Api/Handler.cs' "$BACKEND")"

# --- Brace alternation and character classes (review 5271520178, finding 2)
# These are valid VS Code / Copilot glob syntax. They used to be escaped into
# literals AND shattered by a blind comma split, so every rule using them was
# dropped from every chunk while the filter reported success.
BRACE="$(rule brace '**/*.{ts,tsx}')"
CLASS="$(rule class '**/*.[jt]s')"
NEG="$(rule neg '**/*.[!x]s')"
check "Test 3: brace alternation matches its first alternative" "brace.md" \
  "$(run 'src/a.ts' "$BRACE")"
check "Test 4: brace alternation matches its second alternative" "brace.md" \
  "$(run 'src/a.tsx' "$BRACE")"
check "Test 5: brace alternation still excludes a non-member" "" \
  "$(run 'src/a.py' "$BRACE")"
check "Test 6: a character class matches a member" "class.md" \
  "$(run 'src/a.ts' "$CLASS")"
check "Test 7: a character class still excludes a non-member" "" \
  "$(run 'src/a.py' "$CLASS")"
check "Test 8: a negated character class excludes its member" "" \
  "$(run 'src/a.xs' "$NEG")"
check "Test 9: a negated character class keeps a non-member" "neg.md" \
  "$(run 'src/a.js' "$NEG")"

# A comma INSIDE braces is part of one pattern; a comma outside separates two.
MULTI="$(rule multi '**/*.{ts,tsx}, docs/**/*.md')"
check "Test 10: a braced comma does not split the pattern" "multi.md" \
  "$(run 'src/a.tsx' "$MULTI")"
check "Test 11: an unbraced comma still separates two patterns" "multi.md" \
  "$(run 'docs/wiki/ci.md' "$MULTI")"
check "Test 12: neither alternative matches an unrelated file" "" \
  "$(run 'src/a.cs' "$MULTI")"

# --- Fail-open, which is the whole safety property -------------------------
BROKEN="$(rule broken '**/*.{ts')"
UNTERM="$(rule unterm '**/*.[jt')"
check "Test 13: an unbalanced brace fails OPEN, not closed" "broken.md" \
  "$(run 'src/a.cs' "$BROKEN")"
check "Test 14: an unterminated character class fails OPEN" "unterm.md" \
  "$(run 'src/a.cs' "$UNTERM")"
printf 'no frontmatter at all\n' > "$R/plain.md"
check "Test 15: a file with no frontmatter is kept" "plain.md" \
  "$(run 'src/a.cs' "$R/plain.md")"
NOSCOPE="$(rule noscope '')"
check "Test 16: frontmatter declaring no scope is kept" "noscope.md" \
  "$(run 'src/a.cs' "$NOSCOPE")"
ALWAYS="$(rule always 'src/**/*.cs' 'alwaysApply: true')"
check "Test 17: alwaysApply beats a non-matching applyTo" "always.md" \
  "$(run 'docs/wiki/ci.md' "$ALWAYS")"

# A path the consuming repo named explicitly via MANDATORY_CONTEXT_FILES must
# survive whatever its own frontmatter says — the repo made that call per run.
printf '%s\n' 'docs/wiki/ci.md' > "$TMP_DIR/chunk.txt"
printf '%s\n' "$BACKEND" > "$TMP_DIR/cands.txt"
printf '%s\n' "$BACKEND" > "$TMP_DIR/mand.txt"
check "Test 18: a mandatory path survives a non-matching applyTo" "backend.md" \
  "$(bash "$FILTER_SH" "$TMP_DIR/chunk.txt" "$TMP_DIR/cands.txt" "$TMP_DIR/mand.txt" 2>/dev/null | sed "s|^$R/||")"

# --- Wrapper contracts -----------------------------------------------------
: > "$TMP_DIR/empty.txt"
check "Test 19: an empty candidate list produces no output and no error" "0" \
  "$(bash "$FILTER_SH" "$TMP_DIR/chunk.txt" "$TMP_DIR/empty.txt" >/dev/null 2>&1; echo $?)"
check "Test 20: a missing candidate list never fails the caller" "0" \
  "$(bash "$FILTER_SH" "$TMP_DIR/chunk.txt" "$TMP_DIR/nope.txt" >/dev/null 2>&1; echo $?)"

# With no interpreter the wrapper must pass the candidates through unchanged —
# the behaviour that shipped before scope filtering existed. A review with a few
# extra rule paths is the acceptable degradation; one missing its rules is not.
# A PATH carrying coreutils but no interpreter. Emptying PATH entirely would
# also remove `bash` and the `cat`/`dirname` the passthrough itself needs --
# that tests a broken machine, not a missing soft dependency.
FAKEBIN="$TMP_DIR/bin"; mkdir -p "$FAKEBIN"
for _u in bash cat dirname; do
  _src="$(command -v "$_u" 2>/dev/null || true)"
  [ -n "$_src" ] && ln -sf "$_src" "$FAKEBIN/$_u"
done
if [ -x "$FAKEBIN/bash" ] && [ -x "$FAKEBIN/cat" ] && [ -x "$FAKEBIN/dirname" ]; then
  check "Test 21: with no Python the candidates pass through unfiltered" "backend.md" \
    "$(PATH="$FAKEBIN" bash "$FILTER_SH" "$TMP_DIR/chunk.txt" "$TMP_DIR/cands.txt" 2>/dev/null | sed "s|^$R/||")"
else
  echo "⏭️  Test 21: could not stage a coreutils-only PATH — skipping"
fi

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
SUITE_COMPLETED=1
[ "$fail" -eq 0 ]
