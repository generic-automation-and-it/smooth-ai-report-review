#!/bin/bash
# Adversarial LADR-050 tests. No vendor binary, model, network or repo writes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLICE="$SCRIPT_DIR/lib/graph-signals-slice.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_slice() {
  rc=0
  bash "$SLICE" "$work/signals.tsv" < "$work/files" > "$work/out" 2> "$work/err" || rc=$?
}
check() { [ "$1" = "$2" ] || fail "$3 (expected $1, got $2)"; }

# A cap is a byte ceiling, including the marker, not an approximate target.
printf 'src/a.cs\0' > "$work/files"
: > "$work/signals.tsv"
for i in 1 2 3 4 5 6 7 8; do
  printf 'src/a.cs\t%s\t20\tLongFunctionNameWithMultibyte_é_日本語_%s\t0.8\ttrue\n' "$i" "$i" >> "$work/signals.tsv"
done
for cap in 80 256 512 1024 000512; do
  export OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES="$cap"
  run_slice
  bytes="$(wc -c < "$work/out" | tr -d ' ')"
  limit="$(printf '%s' "$cap" | sed 's/^0*//')"
  [ "$bytes" -le "$limit" ] || fail "cap $cap exceeded ($bytes bytes)"
  # A cut is whole-line, so every emitted reference stays a closed code span.
  if [ "$rc" = 0 ]; then
    awk '/^`/ && !/^`[^`]+:[0-9]+` / { bad=1 } END { exit bad }' "$work/out" || fail 'cut split a reference'
    iconv -f UTF-8 -t UTF-8 "$work/out" > /dev/null || fail 'cut split UTF-8'
  else
    check 3 "$rc" 'too-small cap omits the slice'
    check 0 "$bytes" 'an omitted slice writes no marker-only block'
  fi
done
unset OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES

# Coverage is an independent signal: gaps after the top three/five risk rows
# must not disappear merely because the higher-risk functions are covered.
: > "$work/signals.tsv"
for i in 1 2 3 4 5; do
  printf 'src/a.cs\t%s\t20\tCovered%s\t0.9\tfalse\n' "$i" "$i" >> "$work/signals.tsv"
done
for i in 6 7 8 9; do
  printf 'src/a.cs\t%s\t20\tGap%s\t0.1\ttrue\n' "$i" "$i" >> "$work/signals.tsv"
done
OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES=4096 run_slice
check 0 "$rc" 'covered top ranks still render a coverage section'
for i in 6 7 8; do grep -q "Gap$i" "$work/out" || fail "lower-ranked Gap$i disappeared"; done
! grep -q Gap9 "$work/out" || fail 'more than three gaps emitted'
grep -q 'graph' "$work/out" || fail 'coverage wording fails to qualify graph inference'

# A name containing an absolute path must not leak into the TSV or prompt;
# ordinary namespace-qualified names must retain their disambiguating scope.
printf 'src/a.cs\t10\t20\tClass::Alpha\t0.8\tfalse\n' > "$work/signals.tsv"
run_slice
check 0 "$rc" 'qualified symbol renders'
grep -q 'Class::Alpha' "$work/out" || fail 'namespace discarded'
printf 'src/a.cs\t10\t20\t/srv/repo/src/a.cs::Class::Alpha\t0.8\tfalse\n' > "$work/signals.tsv"
run_slice
check 0 "$rc" 'legacy absolute qualified symbol renders'
grep -q 'Class::Alpha' "$work/out" || fail 'legacy namespace discarded'
! grep -q /srv "$work/out" || fail 'legacy absolute path leaked'
printf 'src/a.cs\t10\t20\tAlpha\t1e-10\tfalse\n' > "$work/signals.tsv"
run_slice
check 0 "$rc" 'scientific-notation risk within range renders'
grep -q 'risk 1e-10' "$work/out" || fail 'small numeric risk was lost'
printf 'src/a.cs\t1\t2\tHigher\t0.5\tfalse\n' >> "$work/signals.tsv"
run_slice
head -1 "$work/out" | grep -q Higher || fail 'scientific notation broke numeric risk ordering'

# Treat malformed matching rows as unusable, never as evidence. No stdout on
# failure, including a good row followed by a malformed one.
for row in \
  'src/a.cs\t10\t20\tAlpha' \
  'src/a.cs\tbad\t20\tAlpha\t0.8\ttrue' \
  'src/a.cs\t0\t20\tAlpha\t0.8\ttrue' \
  'src/a.cs\t10\t9\tAlpha\t0.8\ttrue' \
  'src/a.cs\t10\t20\tAlpha\tnope\ttrue' \
  'src/a.cs\t10\t20\tAlpha\t1.5\ttrue' \
  'src/a.cs\t10\t20\tAlpha\t0.8\tnotbool'; do
  printf 'src/a.cs\t1\t2\tGood\t0.9\tfalse\n%b\n' "$row" > "$work/signals.tsv"
  run_slice
  check 1 "$rc" 'malformed matching row rejects the slice'
  check 0 "$(wc -c < "$work/out" | tr -d ' ')" 'no partial evidence on error'
done

# NUL file selection must preserve spaces and literal glob metacharacters.
printf 'src/a [x].cs\t10\t20\tAlpha\t0.8\ttrue\nsrc/a x.cs\t1\t2\tWrong\t1\ttrue\n' > "$work/signals.tsv"
printf 'src/a [x].cs\0' > "$work/files"
run_slice
check 0 "$rc" 'paths containing spaces and globs render'
grep -qF 'src/a [x].cs:10' "$work/out" || fail 'literal filename lost'
! grep -q Wrong "$work/out" || fail 'glob-expanded a literal filename'

# Unsafe paths and code-looking names never enter the prompt as trusted text.
for path in '/outside/a.cs' '../outside/a.cs' 'src/../outside/a.cs'; do
  printf '%s\0' "$path" > "$work/files"
  printf '%s\t1\t2\tAlpha\t0.8\ttrue\n' "$path" > "$work/signals.tsv"
  run_slice
  check 1 "$rc" 'non-repository path rejected'
  check 0 "$(wc -c < "$work/out" | tr -d ' ')" 'no unsafe path output'
done
printf 'src/a.cs\0' > "$work/files"
for name in 'Alpha#123' 'Alpha`injected`' 'Issues Found' '🔴 High Priority'; do
  printf 'src/a.cs\t1\t2\t%s\t0.8\ttrue\n' "$name" > "$work/signals.tsv"
  run_slice
  check 1 "$rc" 'unsafe symbol rejected'
  check 0 "$(wc -c < "$work/out" | tr -d ' ')" 'no unsafe symbol output'
done
printf 'PASS: graph-signals adversarial slice tests\n'
