#!/bin/bash
set -euo pipefail

# Regression test for LADR-035 + LADR-036 (PR #5404 false-block class).
# Part 1 — review-in-chunks.sh: a single-directory oversized group must be
#   halved (not survive the adaptive split intact), per-file diffs must be
#   truncated to MAX_FILE_DIFF_SIZE, and no chunk prompt may exceed 250KB —
#   so no chunk ever times out and drops a .failed flag from sheer prompt size.
# Part 2 — aggregate-reviews.sh: with a failed chunk the posted body must carry
#   the coverage banner AND the decision must fail-close to request_changes;
#   without one, the model's APPROVE passes through and no banner appears.
# Modelled on test-review-chunk-threshold.sh: temp git repo, the real scripts,
# stubbed lib/opencode-with-fallback.sh + bin/timeout shim.

echo "=========================================="
echo "Testing chunk prompt budget enforcement"
echo "=========================================="
echo ""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../" && pwd)"
SOURCE_CHUNKS_SCRIPT="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
SOURCE_AGG_SCRIPT="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/aggregate-reviews.sh"
SOURCE_BALANCE_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/balance-fences.sh"
SOURCE_COUNT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"
# review-in-chunks.sh resolves its per-chunk budget through this validator and
# runs the LADR-055 sidecar extractor after every chunk. Both are real
# dependencies of the script under test, so the sandbox has to carry them —
# omitting the extractor is what left its call path unexercised for its whole
# lifetime, and omitting the validator aborts the run outright.
SOURCE_TIMEOUT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"
SOURCE_EXTRACT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/extract-findings-json.sh"
# The shape predicate review-in-chunks.sh delegates to (LADR-087). Without it
# every chunk is judged structureless and fail-closed, which looks like a gate
# bug rather than a missing file in this harness.
SOURCE_SHAPE_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/review-has-shape.sh"
# aggregate-reviews.sh runs its summary call through the LADR-092 bounded chain,
# which reads its split from split-chunk-budget.sh. Without both in the sandbox
# the summary call dies on "No such file", agg_ok goes false and this harness
# silently tests the fallback-template path instead of the stubbed summary.
SOURCE_SPLIT_CHAIN_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/run-split-chain.sh"
SOURCE_SPLIT_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/split-chunk-budget.sh"
# LADR-100: aggregation strips any holistic section a model still writes.
SOURCE_STRIP_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/strip-holistic-section.sh"
# LADR-050: the per-chunk graph slice. Copied for the same reason as the libs
# above — without it review-in-chunks.sh finds no slice lib and silently emits
# no block, so the harness would pass while testing nothing.
SOURCE_SLICE_LIB="${REPO_ROOT}/.agents/skills/ai-review-report/scripts/lib/graph-signals-slice.sh"
# The lib directory itself, for the wholesale copy in setup_repo.
SOURCE_LIB_DIR="${REPO_ROOT}/.agents/skills/ai-review-report/scripts"

TMP_DIR="$(mktemp -d /tmp/chunk-prompt-budget.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAILURES=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; FAILURES=$((FAILURES + 1)); }

setup_repo() {
  local test_repo="${TMP_DIR}/repo"
  mkdir -p "${test_repo}/.agents/skills/ai-review-report/scripts/lib"
  mkdir -p "${test_repo}/bin"

  cp "${SOURCE_CHUNKS_SCRIPT}" "${test_repo}/.agents/skills/ai-review-report/scripts/review-in-chunks.sh"
  cp "${SOURCE_AGG_SCRIPT}" "${test_repo}/.agents/skills/ai-review-report/scripts/aggregate-reviews.sh"
  cp "${SOURCE_BALANCE_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/balance-fences.sh"
  cp "${SOURCE_COUNT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/count-changed-files.sh"
  cp "${SOURCE_TIMEOUT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/validate-chunk-timeout.sh"
  cp "${SOURCE_EXTRACT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/extract-findings-json.sh"
  cp "${SOURCE_SHAPE_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/review-has-shape.sh"
  cp "${SOURCE_SPLIT_CHAIN_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/run-split-chain.sh"
  cp "${SOURCE_SPLIT_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/split-chunk-budget.sh"
  cp "${SOURCE_STRIP_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/strip-holistic-section.sh"
  cp "${SOURCE_SLICE_LIB}" "${test_repo}/.agents/skills/ai-review-report/scripts/lib/graph-signals-slice.sh"

  # Every remaining lib, copied wholesale rather than one-by-one. This harness
  # previously copied a hand-picked subset, and aggregate-reviews.sh grew
  # dependencies past it (annotate/renumber suggested fixes, review notes,
  # the decision verdict, the runtime-AGENTS.md builder, the findings renderer):
  # the summary call died on a missing file and every assertion after it ran
  # against the failure template instead of the stubbed summary — a silent
  # wrong-path pass. opencode-with-fallback.sh is the deliberate exception; it is
  # stubbed immediately below, so copy it aside rather than leaving the stub and
  # a real transport both in lib/.
  cp "${SOURCE_LIB_DIR}"/lib/*.sh "${test_repo}/.agents/skills/ai-review-report/scripts/lib/" 2>/dev/null || true
  cp "${SOURCE_LIB_DIR}"/lib/*.py "${test_repo}/.agents/skills/ai-review-report/scripts/lib/" 2>/dev/null || true
  rm -f "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh"

  # Stub transport: junk for semantic grouping (forces directory-grouping
  # fallback), a clean APPROVE summary for aggregation, >200 bytes of review
  # text for chunk reviews (so no empty-output .failed flag is dropped).
  cat > "${test_repo}/.agents/skills/ai-review-report/scripts/lib/opencode-with-fallback.sh" << 'EOF'
#!/bin/bash
prompt_file="${@: -1}"
case "$prompt_file" in
  *semantic_grouping_prompt.txt)
    echo "semantic grouping unavailable in test"
    ;;
  *summary_prompt.txt)
    cat << 'SUMMARY'
## 📋 Overall Summary
Test summary: this PR was reviewed by the stubbed transport.

### 🔴 Critical Issues
None found

### 🟠 High Priority Issues
None found

### 🟡 Medium Priority Issues
None found

### 🔵 Low Priority / Nitpicks
None found

## 🎯 Recommendation
**Decision:** APPROVE
**Rationale:** Following policy: 0 critical and 0 high priority issues found - approving

**MACHINE_READABLE_ACTION:** approve

---
DETAILED_SECTION_MARKER
---

## 🔄 Holistic Cross-Chunk Analysis
**Cross-Chunk Issues Found:**

🟡 **Medium Priority Issues**
- **1)** The two stub chunks name the same setting differently.

**Overall Assessment:** No significant cross-chunk concerns identified.
SUMMARY
    ;;
  *)
    printf '### Test Review\n\n'
    # Template-shaped clean review, one section per file the prompt lists. The
    # predicate (lib/review-has-shape.sh) no longer accepts "none found" as a
    # prose substring, and with two or more files every one must be mentioned
    # (review 5263305644) — so the stub reads the inventory back out of the
    # prompt instead of pretending a file-less body is a review.
    awk 'f && !/^- `/ {exit} f {sub(/^- `/,""); sub(/`$/,""); print} /^\*\*Files in this chunk:\*\*$/ {f=1}' "$prompt_file" \
      | while IFS= read -r _p; do printf '### 📄 File: `%s`\n\n**Issues Found:**\n- None found.\n\n**Pre-existing (informational):**\n- None found.\n\n' "$_p"; done
    ;;
esac
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

  # Fixture shape mirrors PR #5404: one directory holding the whole oversized
  # group (the deeper-directory regroup is a no-op there) plus one single file
  # whose diff alone dwarfs every cap.
  mkdir -p huge giant
  local i
  for i in $(seq -w 1 12); do
    echo "base" > "huge/f${i}.txt"
  done
  echo "base" > giant/big.txt
  git add huge giant
  git commit -q -m "base"

  # ~21KB diff per huge file → 'huge' group ≈ 255KB (> MAX_CHUNK_SIZE 100KB).
  # Convergence: halve → 2×~128KB → halve → 4×~64KB ≤ 100KB → 4 chunks.
  for i in $(seq -w 1 12); do
    for j in $(seq 1 280); do
      echo "huge content line ${j} for budget testing padding padding padding padding" >> "huge/f${i}.txt"
    done
  done
  # ~1MB single-file diff → unsplittable single-file group → must be TRUNCATED
  # to MAX_FILE_DIFF_SIZE in the prompt instead of timing the chunk out.
  for j in $(seq 1 14000); do
    echo "giant content line ${j} for budget testing padding padding padding padding" >> giant/big.txt
  done
  git add huge giant
  git commit -q -m "head"

  mkdir -p ci_temp
  {
    for i in $(seq -w 1 12); do
      printf 'huge/f%s.txt\0' "${i}"
    done
    printf 'giant/big.txt\0'
  } > ci_temp/changed_files.txt
}

run_budget_case() {
  local test_repo="${TMP_DIR}/repo"
  local output_file="${TMP_DIR}/budget.out"
  local run_log="${TMP_DIR}/budget.log"

  cd "${test_repo}"
  local from_sha to_sha
  from_sha="$(git rev-parse HEAD~1)"
  to_sha="$(git rev-parse HEAD)"

  GITHUB_OUTPUT="${output_file}" \
  PATH="${test_repo}/bin:${PATH}" \
  bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh "${from_sha}" "${to_sha}" "test-model" "test expertise" > "${run_log}" 2>&1

  # 1. 13 files (> single-chunk threshold 10, < semantic threshold 15) →
  #    directory grouping → giant(1) + huge halved twice (4) = 5 chunks.
  local chunks
  chunks="$(grep '^total_chunks=' "${output_file}" | tail -1 | cut -d'=' -f2)"
  if [ "${chunks}" = "5" ]; then
    pass "total_chunks=5"
  else
    fail "expected total_chunks=5, got '${chunks}' (see ${run_log})"
  fi

  # 2. The single-directory group must have taken the halving fallback.
  if grep -q "halving (single directory, cannot split deeper)" "${run_log}"; then
    pass "halving fallback log line present"
  else
    fail "halving fallback log line missing from run log"
  fi

  # 3. Hard ceiling: no chunk prompt may exceed 250,000 bytes.
  local oversized=0 prompt size
  local prompts=()
  shopt -s nullglob
  prompts=(ci_temp/chunk_*_prompt.txt)
  shopt -u nullglob
  if [ "${#prompts[@]}" -eq 0 ]; then
    fail "expected chunk prompt files to be generated"
    return
  fi
  for prompt in "${prompts[@]}"; do
    size="$(wc -c < "${prompt}" | tr -d ' ')"
    if [ "${size}" -gt 250000 ]; then
      echo "   oversized prompt: ${prompt} (${size} bytes)"
      oversized=$((oversized + 1))
    fi
  done
  if [ "${oversized}" -eq 0 ]; then
    pass "all chunk prompts ≤ 250000 bytes"
  else
    fail "${oversized} chunk prompt(s) exceed 250000 bytes"
  fi

  # 4. The giant single-file diff must have been truncated, not appended whole.
  if grep -l "has been TRUNCATED" "${prompts[@]}" > /dev/null 2>&1; then
    pass "truncation marker present in at least one prompt"
  else
    fail "no prompt contains the truncation marker"
  fi

  # 5. Bounded prompts must mean zero failed chunks (the PR #5404 symptom).
  if ls ci_temp/reviews/chunk_*.failed > /dev/null 2>&1; then
    fail "unexpected chunk_*.failed flag file(s) exist"
  else
    pass "no chunk_*.failed flag files"
  fi
}

run_aggregation_case() {
  local with_failed_flag="$1"
  local expected_action="$2"
  local expect_banner="$3"
  local label="$4"
  local test_repo="${TMP_DIR}/repo"
  local output_file="${TMP_DIR}/${label}.out"
  local run_log="${TMP_DIR}/${label}.log"

  cd "${test_repo}"
  rm -rf ci_temp
  mkdir -p ci_temp/reviews
  printf '### 📄 File: `huge/f01.txt`\n\n- 🔵 [VERIFIED] Low Priority: None found\n' > ci_temp/reviews/chunk_0.md
  printf '### 📄 File: `giant/big.txt`\n\n- 🔵 [VERIFIED] Low Priority: None found\n' > ci_temp/reviews/chunk_1.md
  if [ "${with_failed_flag}" = "true" ]; then
    echo "exit code 124" > ci_temp/reviews/chunk_1.failed
  fi

  GITHUB_OUTPUT="${output_file}" \
  PATH="${test_repo}/bin:${PATH}" \
  bash .agents/skills/ai-review-report/scripts/aggregate-reviews.sh "2" "test-model" "full" "aaaaaaa1234" "2" "bbbbbbb5678" "test expertise" "none" > "${run_log}" 2>&1

  # The stubbed summary must actually be what aggregated. If the sandbox lacks a
  # lib the summary call needs, the run still completes — on the failure
  # template — and every assertion below would be testing the wrong path.
  if grep -q 'PR summary generated successfully' "${run_log}"; then
    pass "${label}: the stubbed summary call succeeded (sandbox carries the summary chain)"
  else
    fail "${label}: summary call failed in the sandbox — a lib is missing from setup_repo (see ${run_log})"
  fi

  # LADR-100: the stub still writes the old marker and a holistic section, as a
  # model might from habit. Neither may reach the posted body, and the verdict
  # section before them must survive.
  if ! grep -q 'Holistic Cross-Chunk\|DETAILED_SECTION_MARKER\|The two stub chunks' ci_temp/final_review.md \
     && grep -q '^## 🎯 Recommendation' ci_temp/final_review.md; then
    pass "${label}: no holistic section in the posted body; the Recommendation is kept"
  else
    fail "${label}: a holistic section reached the posted body, or the Recommendation was lost (see ci_temp/final_review.md)"
  fi

  local action
  action="$(grep '^review_action=' "${output_file}" | tail -1 | cut -d'=' -f2)"
  if [ "${action}" = "${expected_action}" ]; then
    pass "${label}: review_action=${action}"
  else
    fail "${label}: expected review_action=${expected_action}, got '${action}' (see ${run_log})"
  fi

  if [ "${expect_banner}" = "true" ]; then
    if grep -q "Review coverage incomplete" ci_temp/final_review.md; then
      pass "${label}: coverage banner present in final_review.md"
    else
      fail "${label}: coverage banner missing from final_review.md"
    fi
  else
    if grep -q "Review coverage incomplete" ci_temp/final_review.md; then
      fail "${label}: coverage banner present despite zero failed chunks"
    else
      pass "${label}: no coverage banner"
    fi
  fi

  # LADR-036 prompt rules must be in the aggregation prompt (full review).
  if [ "${with_failed_flag}" = "true" ]; then
    if grep -q "Review-Coverage Gaps Are NOT Code Issues" ci_temp/summary_prompt.txt; then
      pass "${label}: coverage-gaps block present in summary prompt"
    else
      fail "${label}: coverage-gaps block missing from summary prompt"
    fi
    # LADR-100 removed the holistic checklist that carried the scoped
    # "missing implementations" bullet; the coverage-gaps block above is the
    # rule that remains. The checklist must not come back.
    if grep -q "Missing implementations\|Cross-Chunk Issues Found" ci_temp/summary_prompt.txt; then
      fail "${label}: the holistic checklist is back in the summary prompt"
    else
      pass "${label}: no holistic checklist in the summary prompt"
    fi
  fi
}

run_graph_signals_case() {
  local test_repo="${TMP_DIR}/repo"
  local cap=1024

  cd "${test_repo}"
  local from_sha to_sha
  from_sha="$(git rev-parse HEAD~1)"
  to_sha="$(git rev-parse HEAD)"

  # A signals TSV covering two of the fixture's changed files: one high-risk and
  # untested, one low-risk and covered. `giant/big.txt` is deliberately absent
  # so the "only this chunk's files" filter has something to exclude.
  cat > "${TMP_DIR}/graph-signals.tsv" <<'TSV'
huge/f01.txt	1	9	HandleChunk	0.82	true
huge/f02.txt	1	9	RenderChunk	0.31	false
giant/elsewhere.txt	1	2	NotInThisChunk	0.99	true
TSV

  local run_dir prompts=() prompt
  run_dir=0
  while [ "${run_dir}" -lt 10 ]; do
    local label flag with_tsv graph_state=true structured=1
    case "${run_dir}" in
      # A: flag on, signals present — the block must appear.
      0) label="signals-on";  flag=1; with_tsv=1 ;;
      # B: flag on, no signals file — must degrade to today's prompt, silently.
      1) label="signals-absent"; flag=1; with_tsv=0 ;;
      # C: flag off, signals present — must be byte-identical to B.
      2) label="signals-off"; flag=0; with_tsv=1 ;;
      3) label="graph-failed"; flag=1; with_tsv=1; graph_state=failed ;;
      4) label="graph-disabled"; flag=1; with_tsv=1; graph_state=disabled ;;
      5) label="signals-malformed"; flag=1; with_tsv=1 ;;
      6) label="slice-missing"; flag=1; with_tsv=1 ;;
      7) label="sidecar-off"; flag=1; with_tsv=1; structured=0 ;;
      8) label="default-unset"; flag=unused; with_tsv=1 ;;
      9) label="default-empty"; flag=""; with_tsv=1 ;;
    esac

    rm -rf ci_temp/reviews
    mkdir -p ci_temp/reviews
    rm -f ci_temp/chunk_*_prompt.txt
    cp "${TMP_DIR}/graph-signals.tsv" ci_temp/graph_review_signals.tsv
    [ "${with_tsv}" -eq 1 ] || rm -f ci_temp/graph_review_signals.tsv
    if [ "$label" = signals-malformed ]; then
      printf 'huge/f01.txt\tbad\t20\tBad\t0.8\ttrue\n' > ci_temp/graph_review_signals.tsv
    fi
    if [ "$label" = slice-missing ]; then
      mv .agents/skills/ai-review-report/scripts/lib/graph-signals-slice.sh "${TMP_DIR}/slice.saved"
    fi

    local run_rc=0
    local flag_env=(env "OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=$flag")
    if [ "$label" = default-unset ]; then flag_env=(env -u OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS); fi
    GITHUB_OUTPUT="${TMP_DIR}/${label}.out" \
    PATH="${test_repo}/bin:${PATH}" \
    GRAPH_ANALYSIS_AVAILABLE="$graph_state" \
    OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS="$structured" \
    OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES="${cap}" \
    "${flag_env[@]}" bash .agents/skills/ai-review-report/scripts/review-in-chunks.sh "${from_sha}" "${to_sha}" "test-model" "test expertise" \
      > "${TMP_DIR}/${label}.log" 2>&1 || run_rc=$?
    if [ "$label" = slice-missing ]; then
      mv "${TMP_DIR}/slice.saved" .agents/skills/ai-review-report/scripts/lib/graph-signals-slice.sh
    fi
    if [ "$run_rc" -ne 0 ]; then
      fail "graph signals ${label}: real chunk script failed (rc=${run_rc})"
      cat "${TMP_DIR}/${label}.log"
      return
    fi
    if find ci_temp/reviews -name 'chunk_*.failed' | grep -q .; then
      fail "graph signals ${label}: unexpected chunk failure"
    else
      pass "graph signals ${label}: review succeeds without failed chunks"
    fi

    shopt -s nullglob
    prompts=(ci_temp/chunk_*_prompt.txt)
    shopt -u nullglob
    if [ "${#prompts[@]}" -eq 0 ]; then
      fail "graph signals ${label}: no chunk prompts were generated (see ${TMP_DIR}/${label}.log)"
      return
    fi
    mkdir -p "${TMP_DIR}/${label}.prompts"
    cp "${prompts[@]}" "${TMP_DIR}/${label}.prompts/"
    if [ "$label" = sidecar-off ]; then
      if grep -q graph_evidence "${prompts[@]}"; then
        fail 'graph signals: graph_evidence leaks with sidecar off'
      else
        pass 'graph signals: graph_evidence absent with sidecar off'
      fi
    fi

    # Snapshot each prompt's graph block so the three runs can be compared
    # byte-for-byte rather than by eyeball. Markers delimit the per-prompt
    # blocks so an all-empty run is distinguishable from a run of separators.
    : > "${TMP_DIR}/${label}.blocks"
    for prompt in "${prompts[@]}"; do
      printf '<<<BLOCK\n' >> "${TMP_DIR}/${label}.blocks"
      awk '
        /^## Structural signals \(code graph\)$/ { f = 1 }
        f && /^## ⚠️ CRITICAL: REVIEW SCOPE/ { f = 0 }
        f { print }
      ' "${prompt}" >> "${TMP_DIR}/${label}.blocks"
      printf 'BLOCK>>>\n' >> "${TMP_DIR}/${label}.blocks"
    done

    if [ "${run_dir}" -eq 0 ]; then
      if grep -q '## Structural signals (code graph)' "${prompts[@]}"; then
        pass "graph signals: the block is present when the flag is on and signals exist"
      else
        fail "graph signals: no prompt carries the block despite the flag and a signals file (see ${TMP_DIR}/${label}.log)"
      fi

      # The block must be scoped to THIS chunk: giant/elsewhere.txt is in the
      # TSV with the highest risk in the fixture and must not leak into a huge/
      # chunk. A leak would make the model reason about a file it was not given.
      if grep -q 'giant/elsewhere.txt' "${TMP_DIR}/${label}.blocks"; then
        fail "graph signals: the slice leaked a function belonging to another chunk"
      else
        pass "graph signals: the slice is scoped to the chunk's own files"
      fi

      # Both signals must actually render, and the risk number must be carried.
      if grep -q 'risk 0.82' "${TMP_DIR}/${label}.blocks" \
         && grep -q 'no test coverage' "${TMP_DIR}/${label}.blocks" \
         && grep -q 'risk 0.31' "${TMP_DIR}/${label}.blocks"; then
        pass "graph signals: risk and test-coverage both render, including a covered function"
      else
        fail "graph signals: risk or coverage missing from the rendered block"
      fi

      # LADR-045/LADR-067: the block must never tell the reviewer to write a
      # test, and must never carry a LADR-067 autolink.
      if grep -qiE 'add a test|write a test|create a test' "${TMP_DIR}/${label}.blocks"; then
        fail "graph signals: the block instructs a test edit — LADR-045 would revert it"
      else
        pass "graph signals: the block never instructs a test edit"
      fi
      if grep -qE '#[0-9]+' "${TMP_DIR}/${label}.blocks"; then
        fail "graph signals: the block contains #+digits (LADR-067 autolinks it in the posted body)"
      else
        pass "graph signals: no #+digits in the block"
      fi

      # LADR-035: the block is additive but must stay inside its own cap.
      local over=0 total=0
      for prompt in "${prompts[@]}"; do
        local block
        block="$(awk '
          /^## Structural signals \(code graph\)$/ { f = 1 }
          f && /^## ⚠️ CRITICAL: REVIEW SCOPE/ { f = 0 }
          f { print }
        ' "${prompt}" | wc -c | tr -d ' ')"
        total=$((total + block))
        [ "${block}" -le $((cap + 1024)) ] || over=$((over + 1))
      done
      if [ "${over}" -eq 0 ]; then
        pass "graph signals: every rendered block stays within cap+guardrails (${cap}+1024), total ${total} bytes"
      else
        fail "graph signals: ${over} block(s) exceeded cap+disclaimer"
      fi

      # A covered function must not be dressed as a coverage claim.
      if awk '/risk 0.31/ && /no test coverage/ { bad=1 } END { exit bad }' "${TMP_DIR}/${label}.blocks"; then
        pass "graph signals: a covered function is not labelled untested"
      else
        fail "graph signals: a covered function (risk 0.31) is labelled 'no test coverage'"
      fi
    fi

    run_dir=$((run_dir + 1))
  done

  # B (flag on, no signals) and C (flag off, signals present) must agree
  # byte-for-byte. This is the whole fail-open contract: a missing slice, an
  # unparseable one, or an operator flipping the Variable off must all produce
  # exactly the prompt this pipeline shipped before LADR-050.
  # Compare WHOLE prompts. Comparing only empty block extracts passes even
  # when graph-specific instructions leak elsewhere in the disabled prompt.
  local baseline="${TMP_DIR}/signals-off.prompts" label prompt base_size with_size
  for label in default-unset default-empty; do
    if diff -rq "${TMP_DIR}/signals-on.prompts" "${TMP_DIR}/${label}.prompts" > /dev/null; then
      pass "graph signals: $label enables identical full prompts to explicit on"
    else
      fail "graph signals: $label failed to enable the graph hints by default"
    fi
  done
  for label in signals-absent graph-failed graph-disabled signals-malformed slice-missing; do
    if diff -rq "$baseline" "${TMP_DIR}/${label}.prompts" > /dev/null; then
      pass "graph signals: $label produces byte-identical full prompts to flag-off"
    else
      fail "graph signals: $label changed the disabled full prompts"
    fi
  done
  for prompt in "$baseline"/*; do
    base_size="$(wc -c < "$prompt" | tr -d ' ')"
    with_size="$(wc -c < "${TMP_DIR}/signals-on.prompts/$(basename "$prompt")" | tr -d ' ')"
    if [ "$with_size" -lt "$base_size" ] || [ "$with_size" -gt $((base_size + cap + 1024)) ]; then
      fail 'graph signals: additive full-prompt budget exceeded'
    fi
  done

  # A graph block alone is not a completed review. Keep the single predicate
  # unchanged rather than teaching it to accept enrichment as model output.
  if bash .agents/skills/ai-review-report/scripts/lib/review-has-shape.sh "${TMP_DIR}/signals-on.blocks" > /dev/null 2>&1; then
    fail 'graph signals: graph context passed as a completed review'
  else
    pass 'graph signals: graph-only content cannot pass the review-shape gate'
  fi

  # "No block at all" means every per-prompt block is empty: the snapshot holds
  # only its own markers.
  block_lines() {
    grep -v -e '^$' -e '^<<<BLOCK$' -e '^BLOCK>>>$' "$1" 2>/dev/null | wc -l | tr -d ' '
  }
  if [ "$(block_lines "${TMP_DIR}/signals-absent.blocks")" = "0" ] \
     && [ "$(block_lines "${TMP_DIR}/signals-off.blocks")" = "0" ]; then
    pass "graph signals: neither the flag-on run with no signals file nor the flag-off run emits a block"
  else
    fail "graph signals: a block was emitted although the signals file was absent or the flag off"
  fi
}

setup_repo
run_budget_case
run_graph_signals_case
run_aggregation_case "true" "request_changes" "true" "failed-chunk-fail-closed"
run_aggregation_case "false" "approve" "false" "clean-approve-passthrough"

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "=========================================="
  echo "Chunk prompt budget tests FAILED (${FAILURES})"
  echo "=========================================="
  exit 1
fi
echo "=========================================="
echo "Chunk prompt budget tests passed"
echo "=========================================="
