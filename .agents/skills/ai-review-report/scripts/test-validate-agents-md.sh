#!/bin/bash
# Regression tests for validate-agents-md.sh (#207).
#
# Two independent defects combined to false-block a valid PR:
#   1. run-review.sh supplied *_FOR_VALIDATION names the validator never read,
#      so every renamed AGENTS.md fell into the "new file" fallback and was
#      template-validated instead of grandfathered.
#   2. `echo "$content" | grep -q` under `set -o pipefail`: grep -q exits at the
#      first match, echo gets Broken pipe while still writing a large file, and
#      the pipeline reports failure — a successful match became a missing
#      section.
set -eo pipefail

if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "❌ Requires Bash >= 4 (found ${BASH_VERSION:-unknown}). On macOS: 'brew install bash'." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/validate-agents-md.sh"
RUN_REVIEW="$SCRIPT_DIR/run-review.sh"
BASH_BIN="${BASH:-bash}"

TMP_DIR="$(mktemp -d /tmp/validate-agents-md.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "${actual}" = "${expected}" ]; then
    pass "${name}"
  else
    fail "${name} (expected '${expected}', got '${actual}')"
  fi
}

git_q() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

read_validation_passed() {
  grep '^validation_passed=' "$1" | tail -1 | cut -d'=' -f2
}

# Runs the validator in $1, writing GITHUB_OUTPUT to $2, with any remaining
# arguments passed as NAME=value pairs (the validator's env contract).
run_validator() {
  local dir="$1" output_file="$2"
  shift 2
  (
    cd "${dir}"
    env "$@" GITHUB_OUTPUT="${output_file}" "${BASH_BIN}" "${SOURCE_SCRIPT}" full
  )
}

write_large_agents_file() {
  {
    printf '## TL;DR\nLarge fixture; the heading is present from the first line.\n\n'
    head -c 150000 /dev/zero | tr '\0' 'x'
    printf '\n\n## Changelog\n\n| Date | Change | Ref |\n|---|---|---|\n'
    head -c 5000 /dev/zero | tr '\0' 'y'
  } > "$1"
}

# --- Large new file: a matched heading is a pass, not a Broken pipe ----------
large_dir="${TMP_DIR}/large"
mkdir -p "${large_dir}/ci_temp" "${large_dir}/src/Big"
printf 'src/Big/AGENTS.md\0' > "${large_dir}/ci_temp/changed_files.txt"
write_large_agents_file "${large_dir}/src/Big/AGENTS.md"

run_validator "${large_dir}" "${TMP_DIR}/large.out" >"${TMP_DIR}/large.log" 2>"${TMP_DIR}/large.err"
check "large new file with ## TL;DR passes" "true" "$(read_validation_passed "${TMP_DIR}/large.out")"

if grep -q 'Broken pipe' "${TMP_DIR}/large.err"; then
  broken="yes"
else
  broken="no"
fi
check "no Broken pipe writing a large file into grep -q" "no" "${broken}"

# --- Large new file missing the heading still blocks -------------------------
missing_dir="${TMP_DIR}/missing"
mkdir -p "${missing_dir}/ci_temp" "${missing_dir}/src/Big"
printf 'src/Big/AGENTS.md\0' > "${missing_dir}/ci_temp/changed_files.txt"
{
  printf '## Changelog\n\n| Date | Change | Ref |\n|---|---|---|\n'
  head -c 150000 /dev/zero | tr '\0' 'x'
} > "${missing_dir}/src/Big/AGENTS.md"

run_validator "${missing_dir}" "${TMP_DIR}/missing.out" >"${TMP_DIR}/missing.log" 2>&1
check "large new file without ## TL;DR still fails" "false" "$(read_validation_passed "${TMP_DIR}/missing.out")"

# --- No headings at all: the structural check must not abort under set -e ----
plain_dir="${TMP_DIR}/plain"
mkdir -p "${plain_dir}/ci_temp" "${plain_dir}/src/Plain"
printf 'src/Plain/AGENTS.md\0' > "${plain_dir}/ci_temp/changed_files.txt"
printf 'plain text with no ## headings\n' > "${plain_dir}/src/Plain/AGENTS.md"

run_validator "${plain_dir}" "${TMP_DIR}/plain.out" >"${TMP_DIR}/plain.log" 2>&1
check "file without headings reports a result instead of aborting" "false" "$(read_validation_passed "${TMP_DIR}/plain.out")"

# --- N/A anti-pattern is still detected after the two-stage capture ----------
na_dir="${TMP_DIR}/na"
mkdir -p "${na_dir}/ci_temp" "${na_dir}/src/NA"
printf 'src/NA/AGENTS.md\0' > "${na_dir}/ci_temp/changed_files.txt"
printf '## TL;DR\nx\n\n## Key Behaviors\nN/A\n\n## Changelog\n\n| Date | Change | Ref |\n' > "${na_dir}/src/NA/AGENTS.md"

run_validator "${na_dir}" "${TMP_DIR}/na.out" >"${TMP_DIR}/na.log" 2>&1
check "empty N/A section still fails structural quality" "false" "$(read_validation_passed "${TMP_DIR}/na.out")"

# --- Rename fixture: a rename is grandfathered, not treated as new -----------
# The renamed file deliberately has no ## Changelog, so a misclassification as
# "new" fails the quality gate while correct grandfathering passes.
rename_repo="${TMP_DIR}/rename"
mkdir -p "${rename_repo}/ci_temp" "${rename_repo}/src/Routing"
git_q -C "${rename_repo}" init -q .
printf '## TL;DR\nrenamed fixture\n' > "${rename_repo}/src/Routing/FEATURE_AGENTS.md"
git_q -C "${rename_repo}" add -A
git_q -C "${rename_repo}" commit -q -m base
base_commit="$(git_q -C "${rename_repo}" rev-parse HEAD)"
git_q -C "${rename_repo}" mv src/Routing/FEATURE_AGENTS.md src/Routing/AGENTS.md
git_q -C "${rename_repo}" commit -q -m rename
head_commit="$(git_q -C "${rename_repo}" rev-parse HEAD)"
printf 'src/Routing/AGENTS.md\0' > "${rename_repo}/ci_temp/changed_files.txt"

run_validator "${rename_repo}" "${TMP_DIR}/rename-canonical.out" \
  BASE_SHA="${base_commit}" HEAD_SHA="${head_commit}" BASE_REF=main \
  >"${TMP_DIR}/rename-canonical.log" 2>&1
if grep -q 'New files detected: 0' "${TMP_DIR}/rename-canonical.log"; then
  detected="0"
else
  detected="$(grep -oE 'New files detected: [0-9]+' "${TMP_DIR}/rename-canonical.log" || true)"
fi
check "BASE_SHA/HEAD_SHA: rename is detected as modified" "0" "${detected}"
check "BASE_SHA/HEAD_SHA: renamed AGENTS.md is grandfathered" "true" "$(read_validation_passed "${TMP_DIR}/rename-canonical.out")"

run_validator "${rename_repo}" "${TMP_DIR}/rename-legacy.out" \
  BASE_SHA_FOR_VALIDATION="${base_commit}" HEAD_SHA_FOR_VALIDATION="${head_commit}" BASE_REF_FOR_VALIDATION=main \
  >"${TMP_DIR}/rename-legacy.log" 2>&1
if grep -q 'New files detected: 0' "${TMP_DIR}/rename-legacy.log"; then
  detected="0"
else
  detected="$(grep -oE 'New files detected: [0-9]+' "${TMP_DIR}/rename-legacy.log" || true)"
fi
check "*_FOR_VALIDATION aliases: rename is detected as modified" "0" "${detected}"
check "*_FOR_VALIDATION aliases: renamed AGENTS.md is grandfathered" "true" "$(read_validation_passed "${TMP_DIR}/rename-legacy.out")"

# --- Caller/validator contract ----------------------------------------------
# The two files drifted apart once; pin the caller to the names the validator
# reads, and pin the absence of the names that caused the drift.
contract=no
if grep -qE '^[[:space:]]*BASE_SHA="\$\{from_sha\}"' "${RUN_REVIEW}" \
  && grep -qE '^[[:space:]]*HEAD_SHA="\$\{head_sha\}"' "${RUN_REVIEW}" \
  && grep -qE '^[[:space:]]*BASE_REF="\$\{base_ref\}"' "${RUN_REVIEW}"; then
  contract=yes
fi
check "run-review.sh supplies BASE_SHA/HEAD_SHA/BASE_REF" "yes" "${contract}"

if grep -qE '_(FOR_VALIDATION)="' "${RUN_REVIEW}"; then
  drift=present
else
  drift=absent
fi
check "run-review.sh has no *_FOR_VALIDATION assignment" "absent" "${drift}"

# --- Structural guard: no writer-side SIGPIPE hazard survives ----------------
# grep -q closes the pipe on a match; any surviving `echo "$content" | grep` or
# `git ... | grep -q` re-opens bug 2 on a large enough input.
hazards="$(grep -nE '\| *grep|echo "\$content"' "${SOURCE_SCRIPT}" || true)"
check "validator has no echo|grep or | grep pipelines" "" "${hazards}"

if [ "${FAILURES}" -gt 0 ]; then
  echo ""
  echo "${FAILURES} validate-agents-md test(s) failed"
  exit 1
fi

echo ""
echo "=========================================="
echo "validate-agents-md tests passed"
echo "=========================================="
