#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "Testing AGENTS.md validation on large files"
echo "=========================================="
echo ""

# validate-agents-md.sh runs under `set -o pipefail`. A section check written as
# `echo "$content" | grep -q` fails on a large file whose heading sits near the
# top: grep -q exits on the first match, echo takes SIGPIPE writing the rest,
# and pipefail turns the match into a "missing section" false positive.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../" && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/validate-agents-md.sh"

TMP_DIR="$(mktemp -d /tmp/validate-agents-md-large-file.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

CHANGELOG='\n## Changelog\n\n| Date | Change | Ref |\n|------|--------|-----|\n| 2026-10-05 | Initial. | |\n\n'

# $2 = "early" puts the Changelog heading ahead of the padding, so the
# Changelog check matches near the top too.
write_large_agents_md() {
  local path="$1"
  local changelog_position="${2:-last}"
  mkdir -p "$(dirname "${path}")"
  {
    printf '# Large — AGENTS.md\n\n## TL;DR\n\nA compliant file far bigger than a pipe buffer.\n\n'
    [ "${changelog_position}" = "early" ] && printf "${CHANGELOG}"
    printf '## Key Behaviors\n\n'
    head -c 3000000 /dev/zero | tr '\0' 'a' | fold -w 200
    printf '\n'
    [ "${changelog_position}" = "last" ] && printf "${CHANGELOG}"
    true
  } > "${path}"
}

repo_dir="${TMP_DIR}/repo"
output_file="${TMP_DIR}/validate.out"
log_file="${TMP_DIR}/validate.log"
mkdir -p "${repo_dir}"

(
  cd "${repo_dir}"
  git init -q
  git config user.email test@example.com
  git config user.name test
  write_large_agents_md modified/AGENTS.md early
  git add -A
  git commit -qm base
)
base_sha="$(git -C "${repo_dir}" rev-parse HEAD)"

(
  cd "${repo_dir}"
  write_large_agents_md added/AGENTS.md
  printf '\nOne more line.\n' >> modified/AGENTS.md
  git add -A
  git commit -qm head
  mkdir -p ci_temp
  printf 'added/AGENTS.md\0modified/AGENTS.md\0' > ci_temp/changed_files.txt
)
head_sha="$(git -C "${repo_dir}" rev-parse HEAD)"

(
  cd "${repo_dir}"
  GITHUB_OUTPUT="${output_file}" BASE_SHA="${base_sha}" HEAD_SHA="${head_sha}" \
    bash "${SOURCE_SCRIPT}" full > "${log_file}" 2>&1
) || true

validation_passed="$(grep '^validation_passed=' "${output_file}" | tail -1 | cut -d'=' -f2)"
if [ "${validation_passed}" = "true" ]; then
  pass "a large new AGENTS.md with a TL;DR passes validation"
else
  fail "expected validation_passed=true, got '${validation_passed}'"
  sed -n '1,80p' "${log_file}"
fi

if grep -q "missing required sections" "${log_file}"; then
  fail "large new AGENTS.md reported as missing its TL;DR"
else
  pass "no missing-section false positive on the large new file"
fi

if grep -q "Missing required '## Changelog' section" "${log_file}"; then
  fail "large AGENTS.md reported as missing its Changelog"
else
  pass "no missing-Changelog false positive on the large files"
fi

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} large-file validation test(s) failed"
  exit 1
fi
echo "All large-file validation tests passed"
