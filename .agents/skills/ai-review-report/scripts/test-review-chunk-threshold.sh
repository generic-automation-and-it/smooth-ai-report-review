#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "Testing review chunk threshold behavior"
echo "=========================================="
echo ""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../" && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
SOURCE_COUNT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"
# review-in-chunks.sh calls the LADR-055 sidecar extractor after every chunk.
# Without it in the sandbox the call errored to stderr on every chunk and was
# swallowed by its `|| true`, so the extraction path was silently unexercised
# here from the day it landed.
SOURCE_EXTRACT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/extract-findings-json.sh"
# Same coupling: review-in-chunks.sh resolves its per-chunk budget through the
# shared validator, so a sandbox without it falls back to bash's "No such file"
# and an empty timeout string.
SOURCE_TIMEOUT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"

TMP_DIR="$(mktemp -d /tmp/review-chunk-threshold.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_repo() {
  local test_repo="${TMP_DIR}/repo"
  mkdir -p "${test_repo}/.agents/skills/ai-review-report/scripts/lib"
  mkdir -p "${test_repo}/bin"

  cp "${SOURCE_SCRIPT}" "${test_repo}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
  cp "${SOURCE_COUNT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"
  cp "${SOURCE_EXTRACT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/extract-findings-json.sh"
  cp "${SOURCE_TIMEOUT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"

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
  cp "${SOURCE_EXTRACT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/extract-findings-json.sh"
  cp "${SOURCE_TIMEOUT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"

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
_ct_lib="$REPO_ROOT/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"
_ct() { # _ct <label> <expected> <actual>
  if [ "$3" = "$2" ]; then echo "  ✅ $1"; else echo "  ❌ $1 (expected '$2', got '$3')"; _ct_fail=1; fi
}
# Assert the variable is READ, not that it appears literally at the `timeout`
# call. The original assertion pinned the exact call-site string
# `timeout "${OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT}s"`, which broke the moment
# the value gained the validation SKILL.md had always documented (an
# intermediate `_chunk_timeout` holding the validated value). The behaviour the
# test exists to protect — the variable is honoured, no hardcoded budget creeps
# back — is covered by this check plus the fallback cases below; the shape of
# the call site is an implementation detail and pinning it only produces false
# failures on correct refactors.
_ct "the shared validator exists and is the one the call site names" "1" \
  "$([ -f "$_ct_lib" ] && echo 1 || echo 0)"
_ct "the chunk-timeout variable is read by the gate" "1" \
  "$(cat "$_ric" "$_ct_lib" | grep -cE 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT' | awk '{print ($1 > 0) ? 1 : 0}')"
_ct "no hardcoded 300s chunk timeout remains" "0" \
  "$(grep -c 'timeout 300s' "$_ric")"
_ct "timeout marker reports the configured budget, not a hardcoded 5 minutes" "1" \
  "$(grep -c 'Reason:\*\* Timeout' "$_ric")"
# The call site must resolve the budget THROUGH the shared validator. Without
# this assertion the cases below still pass while `review-in-chunks.sh` reverts
# to an unvalidated `${VAR:-450}` — which is exactly how the previous version of
# this test (a self-contained subshell reproduction of the validator) could stay
# green against a call site that had drifted, or lost its validation entirely.
_ct "the call site resolves the budget via lib/validate-chunk-timeout.sh" "1" \
  "$(grep -c '_chunk_timeout=.*validate-chunk-timeout\.sh' "$_ric")"
_ct "no unvalidated \${VAR:-450} fallback remains at the call site" "0" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:-' "$_ric")"
# The validator must reject junk and fall back rather than pass it to `timeout`.
# `007` is the case the old reproduction got wrong: `^[0-9]+$` accepted it, the
# real `^[1-9][0-9]*$` does not.
for bad in "abc" "0" "-5" "" "007" "45s" "4.5"; do
  out="$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT="$bad" bash "$_ct_lib" 2>/dev/null)"
  _ct "invalid value '$bad' falls back to 450" "450" "$out"
done
_ct "unset falls back to 450" "450" \
  "$(env -u OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT bash "$_ct_lib" 2>/dev/null)"
_ct "a rejected value is reported on stderr, not swallowed" "1" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=abc bash "$_ct_lib" 2>&1 >/dev/null \
     | grep -c 'falling back')"
_ct "valid override is honoured" "1200" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=1200 bash "$_ct_lib" 2>/dev/null)"
_ct "the validated value is a bare integer on stdout" "1" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=abc bash "$_ct_lib" 2>/dev/null \
     | grep -cE '^[1-9][0-9]*$')"
# --- Prompt-size scaling ----------------------------------------------------
# A FIXED budget against VARIABLE work fail-closes honest chunks. PR #111 run
# 30792984316 lost 4 of 6 chunks to exit 124 at exactly 450 s on 135 KB prompts,
# while 88 KB prompts had never timed out — the 450 s was calibrated before
# ~33 KB of instructions (LADR-055/058) started riding on top of a diff already
# allowed up to MAX_CHUNK_SIZE. The budget now scales with the prompt.
_ct "no prompt size given → unchanged base (every existing caller is safe)" "450" \
  "$(bash "$_ct_lib" 2>/dev/null)"
_ct "a small prompt does not scale" "450" \
  "$(bash "$_ct_lib" 44032 2>/dev/null)"
_ct "a prompt at the free allowance does not scale" "450" \
  "$(bash "$_ct_lib" 65536 2>/dev/null)"
_ct "a 135 KB prompt — the size that timed out — scales above the base" "1" \
  "$(bash "$_ct_lib" 138412 2>/dev/null | awk '{print ($1 > 450) ? 1 : 0}')"
_ct "scaling is bounded by the ceiling (deadlock detection survives)" "1200" \
  "$(bash "$_ct_lib" 999999 2>/dev/null)"
_ct "the ceiling is configurable" "700" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX=700 bash "$_ct_lib" 999999 2>/dev/null)"
_ct "a junk ceiling falls back rather than disabling the cap" "1200" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX=abc bash "$_ct_lib" 999999 2>/dev/null)"
_ct "a ceiling below the floor never shortens the base" "450" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX=10 bash "$_ct_lib" 999999 2>/dev/null)"
_ct "a junk prompt size is ignored, not treated as zero-or-huge" "450" \
  "$(bash "$_ct_lib" "not-a-number" 2>/dev/null)"
_ct "an explicit base still scales from that base, not from the default" "1" \
  "$(OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT=600 bash "$_ct_lib" 138412 2>/dev/null | awk '{print ($1 > 600) ? 1 : 0}')"
_ct "scaling is still a bare integer on stdout" "1" \
  "$(bash "$_ct_lib" 138412 2>/dev/null | grep -cE '^[1-9][0-9]*$')"
_ct "scaling is announced on stderr, not silent" "1" \
  "$(bash "$_ct_lib" 138412 2>&1 >/dev/null | grep -c 'scaling the review budget')"
_ct "the call site passes the prompt size to the validator" "1" \
  "$(grep -c 'validate-chunk-timeout\.sh" "\$prompt_size"' "$_ric")"

# Env-var parity: any var the entrypoint reads must be in BOTH packagings.
_ct "declared in the reusable workflow" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:' "$REPO_ROOT/.github/workflows/pipeline-code-review-report.yml")"
_ct "declared in the local-job packaging" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT:' "$REPO_ROOT/.docs/examples/code-review-local.yml")"
_ct "ceiling declared in the reusable workflow" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX:' "$REPO_ROOT/.github/workflows/pipeline-code-review-report.yml")"
_ct "ceiling declared in the local-job packaging" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX:' "$REPO_ROOT/.docs/examples/code-review-local.yml")"
[ "$_ct_fail" -eq 0 ] || exit 1

# --- No-review detection: narration is not a review (LADR-077) ---------------
# The 200-byte floor catches an empty answer. It does not catch the other silent
# no-op: opencode exits 0 having streamed only between-tool narration and never
# writing the review. Consumer run 34745786660 chunk 1 shipped 733 B of exactly
# that — over the floor, so it was logged as completed, counted in total_chunks,
# left failed_chunks at 0, denied the LADR-002 fallback its turn, and posted the
# narration verbatim as the report's `### Chunk 1` section.
echo ""
echo "=========================================="
echo "Testing no-review (narration-only) detection"
echo "=========================================="
_sh_fail=0
_sh() { # _sh <label> <expected> <actual>
  if [ "$3" = "$2" ]; then echo "  ✅ $1"; else echo "  ❌ $1 (expected '$2', got '$3')"; _sh_fail=1; fi
}

setup_shape_repo() {
  local test_repo="${TMP_DIR}/repo-shape"
  rm -rf "${test_repo}"
  mkdir -p "${test_repo}/.agents/skills/ai-review-report/scripts/lib" "${test_repo}/bin"
  cp "${SOURCE_SCRIPT}" "${test_repo}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
  cp "${SOURCE_COUNT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"
  cp "${SOURCE_EXTRACT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/extract-findings-json.sh"
  cp "${SOURCE_TIMEOUT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"

  # The mock replays whatever body the case under test wrote, so one sandbox
  # covers both the narration shape and the honest-review control.
  cat > "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" << 'MOCK'
#!/usr/bin/env bash
prompt_file="${@: -1}"
if [[ "$prompt_file" == *"semantic_grouping_prompt.txt" ]]; then
  echo "semantic grouping unavailable in test"
else
  cat "$MOCK_REVIEW_BODY_FILE"
fi
MOCK
  chmod +x "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"

  # Shebang matters here: this shim IS executed by shebang (as `timeout`), not
  # via an explicit interpreter, and `/bin/bash` does not exist everywhere the
  # suite runs (the bash:5.2 image keeps bash at /usr/local/bin/bash). A missing
  # interpreter surfaces as exit 127 from the model call, which reads exactly
  # like a provider failure and sends every case down the wrong branch.
  cat > "${test_repo}/bin/timeout" << 'EOF'
#!/bin/sh
shift
exec "$@"
EOF
  chmod +x "${test_repo}/bin/timeout"

  # The failure path logs through this lib; without it the branch under test
  # prints "No such file or directory" and the assertion reads as a pass.
  cp "${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/report-error-log.sh" \
    "${test_repo}/.agents/skills/ai-review-report/scripts/lib/report-error-log.sh"

  cd "${test_repo}"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  mkdir -p alpha
  echo "one" > alpha/a.txt
  git add alpha/a.txt
  git commit -q -m "base"
  echo "one updated" >> alpha/a.txt
  git add alpha/a.txt
  git commit -q -m "head"
}

run_shape_case() { # run_shape_case <label> <body_file>
  local label="$1" body_file="$2"
  local test_repo="${TMP_DIR}/repo-shape"
  cd "${test_repo}"
  rm -rf ci_temp
  mkdir -p ci_temp
  printf 'alpha/a.txt\0' > ci_temp/changed_files.txt
  local from_sha to_sha
  from_sha="$(git rev-parse HEAD~1)"
  to_sha="$(git rev-parse HEAD)"
  MOCK_REVIEW_BODY_FILE="${body_file}" \
    GITHUB_OUTPUT="${TMP_DIR}/${label}.out" \
    PATH="${test_repo}/bin:${PATH}" \
    bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh \
      "${from_sha}" "${to_sha}" "test-model" "test expertise" > "${TMP_DIR}/${label}.log" 2>&1
}

setup_shape_repo

# Verbatim shape of the trigger run: prose, over the floor, no severity marker,
# no "None found", no heading — the model talking about what it is about to do.
cat > "${TMP_DIR}/narration.txt" << 'EOF'
I'll start by reading the mandatory context files and checking the referenced documentation paths.
The globs for `.docs/hlds/**` and `.docs/adrs/**` found nothing. Let me verify the actual `.docs` structure to check whether the retargeted references resolve.
The `.docs/hlds/` directory still contains the old ADR filenames — no `002-context-memory-write-pipeline/` folder exists. Let me check for naming consistency across the skill and repo.
The retarget is repo-wide but `.docs/hlds/` itself still holds only the old files. Let me get context on the one remaining old-scheme citation in this skill's folder.
EOF

run_shape_case "narration-only" "${TMP_DIR}/narration.txt"
_sh "narration over the floor is not accepted as a review" "1" \
  "$([ -f "${TMP_DIR}/repo-shape/ci_temp/reviews/chunk_0.failed" ] && echo 1 || echo 0)"
_sh "the flag names the shape, not the byte count" "1" \
  "$(grep -c 'no review structure' "${TMP_DIR}/repo-shape/ci_temp/reviews/chunk_0.failed" 2>/dev/null || true)"
_sh "the narration is replaced by a visible failure marker in the body" "1" \
  "$(grep -c 'Review Failed for Chunk' "${TMP_DIR}/repo-shape/ci_temp/reviews/chunk_0.md" 2>/dev/null || true)"
_sh "the run log says the chunk produced no usable review" "1" \
  "$(grep -c 'produced no usable review' "${TMP_DIR}/narration-only.log" 2>/dev/null || true)"

# Control: an honest review must be untouched. A false positive here is worse
# than the bug — the flag is fail-closed (LADR-031), so it blocks a clean PR.
{
  printf '### Review\n\n'
  printf -- '- 🟠 [VERIFIED] High Priority: real finding with a location — `alpha/a.txt:1`. The appended line is never read back, so the value written above it cannot be verified by any caller.\n'
  printf -- '- 🔵 [SPECULATIVE] Low Priority: an observation about naming in the same file, offered as a question rather than a defect.\n\n'
  printf '**Pre-existing (informational):** None found.\n\n**Suggested Fixes:** covered inline above.\n'
} > "${TMP_DIR}/real-review.txt"
run_shape_case "real-review" "${TMP_DIR}/real-review.txt"
_sh "an honest review is not flagged" "0" \
  "$([ -f "${TMP_DIR}/repo-shape/ci_temp/reviews/chunk_0.failed" ] && echo 1 || echo 0)"
_sh "an honest review keeps its body" "1" \
  "$(grep -c 'real finding with a location' "${TMP_DIR}/repo-shape/ci_temp/reviews/chunk_0.md" 2>/dev/null || true)"

# A body carrying only severity emoji (no headings, no "Priority" wording) still
# counts — the matcher answers "is there review shape here", not "is it complete".
printf 'Findings, listed without headings or the word priority anywhere in the body:\n🟡 stale link in the doc header, `alpha/a.txt:1` — retarget it to the committed path.\n%.0s' {1..4} \
  > "${TMP_DIR}/emoji-only.txt"
run_shape_case "emoji-only" "${TMP_DIR}/emoji-only.txt"
_sh "a severity emoji alone is review shape" "0" \
  "$([ -f "${TMP_DIR}/repo-shape/ci_temp/reviews/chunk_0.failed" ] && echo 1 || echo 0)"

if [ "$_sh_fail" -ne 0 ]; then
  for _l in narration-only real-review emoji-only; do
    echo "--- ${_l}.log (tail) ---"
    tail -25 "${TMP_DIR}/${_l}.log" 2>/dev/null || true
  done
  exit 1
fi
