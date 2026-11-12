#!/usr/bin/env bash
# Offline regression test for format-fix-skip-output.sh: the posted FIX/SKIP
# table must render as a GitHub table whatever the model wrote around it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fmt="$here/lib/format-fix-skip-output.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

pass=0
expect() {
  local name="$1" input="$2" want="$3" got
  printf '%s' "$input" > "$scratch/in"
  got="$(bash "$fmt" "$scratch/in")"
  if [ "$got" != "$want" ]; then
    echo "❌ $name" >&2
    printf -- '--- want ---\n%s\n--- got ---\n%s\n' "$want" "$got" >&2
    exit 1
  fi
  # Idempotent: formatting the output again changes nothing.
  printf '%s\n' "$got" > "$scratch/again"
  if [ "$(bash "$fmt" "$scratch/again")" != "$got" ]; then
    echo "❌ $name: not idempotent" >&2
    exit 1
  fi
  echo "  ✅ $name"
  pass=$((pass + 1))
}

# The gf-ipc-smart-card PR 111 comment: a numbered note glued to the header
# made GitHub render the whole table as text inside that list item.
expect "narration glued above the table is split off" \
'1. The Understanding store is absent; proceeding from the runbooks.
| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|
| 1. | FIX | Medium | `docs/runbooks/reader-name.md` | Corrected step 4. | Documentation-only fix. |
' \
'1. The Understanding store is absent; proceeding from the runbooks.

| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|
| 1. | FIX | Medium | `docs/runbooks/reader-name.md` | Corrected step 4. | Documentation-only fix. |'

expect "a clean table is unchanged" \
'| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|
| 2. | SKIP | Low | a.sh | two | deferred |
' \
'| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|
| 2. | SKIP | Low | a.sh | two | deferred |'

expect "an indented table is un-indented" \
'Fixes:
    | # | Decision |
    |---|----------|
    | 1. | FIX |
' \
'Fixes:

| # | Decision |
|---|----------|
| 1. | FIX |'

expect "a note glued below the table is split off" \
'| # | Decision |
|---|----------|
| 1. | FIX |
No other file changes were needed.
' \
'| # | Decision |
|---|----------|
| 1. | FIX |

No other file changes were needed.'

expect "pipes inside a code fence are left alone" \
'```
| not | a table |
```
| # | Decision |
|---|----------|
' \
'```
| not | a table |
```

| # | Decision |
|---|----------|'

expect "CRLF line endings are normalised" \
"$(printf 'Note.\r\n| # | Decision |\r\n|---|----------|\r\n')" \
'Note.

| # | Decision |
|---|----------|'

expect "text with no table passes through" \
'No items in scope after deterministic filters; model call skipped.
' \
'No items in scope after deterministic filters; model call skipped.'

echo "format-fix-skip-output: ${pass} passed"
