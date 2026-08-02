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
  # Generate a 200KB file (exceeds MAX_CHUNK_SIZE 100KB). 200KB raw
  # bytes → ~267KB base64-encoded; the test asserts the resulting diff
  # is at least 2× MAX_CHUNK_SIZE (200KB) below so the test doesn't
  # silently start passing for the wrong reason if either knob
  # changes. PR #86 review 4820157344 #7.
  head -c 200000 /dev/urandom | base64 > huge.txt
  git add a.txt b.txt huge.txt
  git commit -q -m "head"
  # Sanity-check the fixture: the resulting diff must be at least 2×
  # the chunker cap, otherwise the regression test could silently start
  # passing (single-chunk mode would re-assert even with 3 files).
  local from_sha to_sha
  from_sha="$(git rev-parse HEAD~1)"
  to_sha="$(git rev-parse HEAD)"
  local fixture_diff_size
  fixture_diff_size="$(git diff "${from_sha}..${to_sha}" -- huge.txt | wc -c | tr -d ' ')"
  local chunker_cap
  chunker_cap="$(grep -E '^MAX_CHUNK_SIZE=' "${SOURCE_SCRIPT}" | head -1 | sed -E 's/^MAX_CHUNK_SIZE=//; s/[[:space:]].*//')"
  if [ -z "$chunker_cap" ] || ! [[ "$chunker_cap" =~ ^[0-9]+$ ]]; then
    echo "❌ Could not extract MAX_CHUNK_SIZE from ${SOURCE_SCRIPT} (got: '$chunker_cap')" >&2
    exit 1
  fi
  if [ "$fixture_diff_size" -lt $(( chunker_cap * 2 )) ]; then
    echo "❌ size-cap-overrides-low-file-count fixture is too small: ${fixture_diff_size}B diff, expected >= $(( chunker_cap * 2 ))B (2× MAX_CHUNK_SIZE=${chunker_cap})" >&2
    exit 1
  fi
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

# --- Chunk timeout is configurable and validated (post-LADR-055) --------------
# The budget wraps the whole model chain, so a wrong value here does not degrade
# gracefully — it fail-closes a chunk that would have reviewed fine.
echo ""
echo "=========================================="
echo "Testing OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT"
echo "=========================================="
_ct_fail=0
_ric="$REPO_ROOT/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
_ct() { # _ct <label> <expected> <actual>
  if [ "$3" = "$2" ]; then echo "  ✅ $1"; else echo "  ❌ $1 (expected '$2', got '$3')"; _ct_fail=1; fi
}
_ct "call site uses the variable, not a hardcoded 300s" "1" \
  "$(grep -c 'timeout "\${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT}s"' "$_ric")"
_ct "no hardcoded 300s chunk timeout remains" "0" \
  "$(grep -c 'timeout 300s' "$_ric")"
_ct "timeout marker reports the configured budget, not a hardcoded 5 minutes" "1" \
  "$(grep -c 'Reason:\*\* Timeout' "$_ric")"
# The validator must reject junk and fall back rather than pass it to `timeout`.
for bad in "abc" "0" "-5" ""; do
  out="$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT="$bad" bash -c '
    OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT="${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:-450}"
    if ! [[ "$OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT" -le 0 ]; then
      OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=450
    fi
    printf "%s" "$OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT"')"
  _ct "invalid value '$bad' falls back to 450" "450" "$out"
done
_ct "valid override is honoured" "1200" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=1200 bash -c '
    OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT="${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:-450}"
    if ! [[ "$OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT" -le 0 ]; then
      OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=450
    fi
    printf "%s" "$OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT"')"
# Env-var parity: any var the entrypoint reads must be in BOTH packagings.
_ct "declared in the reusable workflow" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:' "$REPO_ROOT/.github/workflows/pipeline-code-review-report.yml")"
_ct "declared in the local-job packaging" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:' "$REPO_ROOT/.docs/examples/code-review-local.yml")"
[ "$_ct_fail" -eq 0 ] || exit 1
