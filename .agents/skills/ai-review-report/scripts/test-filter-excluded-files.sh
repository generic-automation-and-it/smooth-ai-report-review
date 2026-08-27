#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$SCRIPT_DIR/filter-excluded-files.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS $name"
    pass=$((pass + 1))
  else
    echo "  FAIL $name: expected '$expected', got '$actual'"
    fail=$((fail + 1))
  fi
}

write_changed() {
  rm -f ci_temp/excluded_files.txt
  printf 'generated/Generated.cs\0current.txt\0removed.txt\0' > ci_temp/changed_files.txt
}

count_changed() {
  tr '\0' '\n' < ci_temp/changed_files.txt | grep -c . || true
}

cd "$TMP_DIR"
git init -q
git config user.email test@example.invalid
git config user.name Test
mkdir generated
printf 'generated\n' > generated/Generated.cs
printf 'removed\n' > removed.txt
git add .
git commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
rm generated/Generated.cs removed.txt
printf 'current\n' > current.txt
git add -A
git commit -qm head
HEAD_SHA="$(git rev-parse HEAD)"
mkdir ci_temp

write_changed
bash "$FILTER" >/dev/null
check "filters default off" "3" "$(count_changed)"

write_changed
OPENCODE_REVIEW_REPORT_EXCLUDE_GENERATED_PATHS="generated/Generated.cs" bash "$FILTER" >/dev/null
check "generated exact-path filter removes matching path" "2" "$(count_changed)"

write_changed
OPENCODE_REVIEW_REPORT_EXCLUDE_GENERATED_PATHS="generated" bash "$FILTER" >/dev/null
check "generated directory filter removes matching paths" "2" "$(count_changed)"
check "generated manifest reason" $'generated\tgenerated/Generated.cs' "$(grep -F 'generated/Generated.cs' ci_temp/excluded_files.txt)"

write_changed
OPENCODE_REVIEW_REPORT_EXCLUDE_DELETED=1 \
  OPENCODE_REVIEW_REPORT_DIFF_FROM_SHA="$BASE_SHA" \
  OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$HEAD_SHA" \
  bash "$FILTER" >/dev/null
check "deleted filter removes deleted paths" "1" "$(count_changed)"
check "deleted manifest reason" $'deleted\tgenerated/Generated.cs' "$(grep -F 'generated/Generated.cs' ci_temp/excluded_files.txt)"

echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
