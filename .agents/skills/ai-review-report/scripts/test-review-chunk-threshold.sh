#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "Testing review chunk threshold behavior"
echo "=========================================="
echo ""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../" && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
SOURCE_COUNT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"

TMP_DIR="$(mktemp -d /tmp/review-chunk-threshold.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_repo() {
  local test_repo="${TMP_DIR}/repo"
  mkdir -p "${test_repo}/.agents/skills/ai-review-report/scripts/lib"
  mkdir -p "${test_repo}/bin"

  cp "${SOURCE_SCRIPT}" "${test_repo}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
  cp "${SOURCE_COUNT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"

  cat > "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" << 'EOF'
#!/bin/bash
prompt_file="${@: -1}"
if [[ "$prompt_file" == *"semantic_grouping_prompt.txt" ]]; then
  echo "semantic grouping unavailable in test"
else
  printf '### Test Review\n\n- 🔵 [VERIFIED] Low Priority: none found in test run.\n\n%.0s' {1..20}
fi
EOF
  chmod +x "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"

  cat > "${test_repo}/bin/timeout" << 'EOF'
#!/bin/bash
shift
exec "$@"
EOF
  chmod +x "${test_repo}/bin/timeout"

  cd "${test_repo}"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  mkdir -p alpha beta gamma
  echo "one" > alpha/a.txt
  echo "two" > beta/b.txt
  echo "three" > gamma/c.txt
  git add alpha/a.txt beta/b.txt gamma/c.txt
  git commit -q -m "base"
  echo "one updated" >> alpha/a.txt
  echo "two updated" >> beta/b.txt
  echo "three updated" >> gamma/c.txt
  git add alpha/a.txt beta/b.txt gamma/c.txt
  git commit -q -m "head"

  mkdir -p ci_temp
  printf 'alpha/a.txt\0beta/b.txt\0gamma/c.txt\0' > ci_temp/changed_files.txt
}

run_case() {
  local threshold="$1"
  local expected="$2"
  local label="$3"
  local test_repo="${TMP_DIR}/repo"
  local output_file="${TMP_DIR}/${label}.out"

  cd "${test_repo}"
  rm -rf ci_temp/reviews
  rm -f ci_temp/chunk_* ci_temp/file_groups* ci_temp/all_context_files.txt ci_temp/semantic_grouping_*
  mkdir -p ci_temp
  printf 'alpha/a.txt\0beta/b.txt\0gamma/c.txt\0' > ci_temp/changed_files.txt

  local from_sha to_sha
  from_sha="$(git rev-parse HEAD~1)"
  to_sha="$(git rev-parse HEAD)"

  if [ -n "${threshold}" ]; then
    OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING="${threshold}" \
    GITHUB_OUTPUT="${output_file}" \
    PATH="${test_repo}/bin:${PATH}" \
    bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh "${from_sha}" "${to_sha}" "test-model" "test expertise" >/dev/null
  else
    GITHUB_OUTPUT="${output_file}" \
    PATH="${test_repo}/bin:${PATH}" \
    bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh "${from_sha}" "${to_sha}" "test-model" "test expertise" >/dev/null
  fi

  local chunks
  chunks="$(grep '^total_chunks=' "${output_file}" | tail -1 | cut -d'=' -f2)"
  if [ "${chunks}" = "${expected}" ]; then
    echo "✅ ${label}: total_chunks=${chunks}"
  else
    echo "❌ ${label}: expected total_chunks=${expected}, got ${chunks}"
    exit 1
  fi
}

setup_repo
run_case "" "1" "default-threshold-single-chunk"
run_case "2" "3" "override-threshold-directory-chunks"

# Regression from PR #86 CI review 4819995397: a 9-file PR whose diff
# exceeded MAX_CHUNK_SIZE used to be reviewed as a single chunk, building
# a 208KB prompt that hit the 5-minute model timeout. The chunker now
# treats MAX_CHUNK_SIZE as a hard upper bound — when file_count is below
# the threshold but the total diff exceeds the cap, it falls through to
# adaptive splitting. To exercise this, generate a single large file
# whose diff alone exceeds MAX_CHUNK_SIZE and verify the chunker splits.
setup_large_file_repo() {
  local test_repo="${TMP_DIR}/repo-large"
  rm -rf "${test_repo}"
  mkdir -p "${test_repo}/.agents/skills/ai-review-report/scripts/lib"
  mkdir -p "${test_repo}/bin"
  cp "${SOURCE_SCRIPT}" "${test_repo}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
  cp "${SOURCE_COUNT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"

  cat > "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" << 'EOF'
#!/bin/bash
prompt_file="${@: -1}"
if [[ "$prompt_file" == *"semantic_grouping_prompt.txt" ]]; then
  echo "semantic grouping unavailable in test"
else
  printf '### Test Review\n\n- 🔵 [VERIFIED] Low Priority: none found in test run.\n\n%.0s' {1..20}
fi
EOF
  chmod +x "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"

  cat > "${test_repo}/bin/timeout" << 'EOF'
#!/bin/bash
shift
exec "$@"
EOF
  chmod +x "${test_repo}/bin/timeout"

  cd "${test_repo}"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  # Two small files
  echo "one" > a.txt
  echo "two" > b.txt
  git add a.txt b.txt
  git commit -q -m "base"
  # Generate a 200KB file (exceeds MAX_CHUNK_SIZE 100KB)
  head -c 200000 /dev/urandom | base64 > huge.txt
  git add a.txt b.txt huge.txt
  git commit -q -m "head"
  mkdir -p ci_temp
  printf 'a.txt\0b.txt\0huge.txt\0' > ci_temp/changed_files.txt
}

run_size_override_case() {
  local label="$1" expected_min="$2"
  local test_repo="${TMP_DIR}/repo-large"
  local output_file="${TMP_DIR}/${label}.out"
  cd "${test_repo}"
  rm -rf ci_temp/reviews
  rm -f ci_temp/chunk_* ci_temp/file_groups* ci_temp/all_context_files.txt ci_temp/semantic_grouping_*
  mkdir -p ci_temp
  printf 'a.txt\0b.txt\0huge.txt\0' > ci_temp/changed_files.txt
  local from_sha to_sha
  from_sha="$(git rev-parse HEAD~1)"
  to_sha="$(git rev-parse HEAD)"
  GITHUB_OUTPUT="${output_file}" \
    PATH="${test_repo}/bin:${PATH}" \
    bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh "${from_sha}" "${to_sha}" "test-model" "test expertise" >/dev/null
  local chunks
  chunks="$(grep '^total_chunks=' "${output_file}" | tail -1 | cut -d'=' -f2)"
  if [ "${chunks}" -ge "${expected_min}" ]; then
    echo "✅ ${label}: total_chunks=${chunks} (>= ${expected_min})"
  else
    echo "❌ ${label}: expected total_chunks >= ${expected_min}, got ${chunks}"
    exit 1
  fi
}

setup_large_file_repo
run_size_override_case "size-cap-overrides-low-file-count" "2"

echo ""
echo "=========================================="
echo "Chunk threshold tests passed"
echo "=========================================="
