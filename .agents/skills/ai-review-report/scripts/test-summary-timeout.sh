#!/bin/bash
# Tests for LADR-092: the aggregation summary call is bounded, and the bound is
# split so a hung orchestrator still leaves the review-model fallback a turn.
#
# Consumer runs 35969611034 and 35995746041 spent 13+ minutes in the summary
# call, which had no timeout at all (lib/opencode-with-fallback.sh has no clock
# of its own) and was bounded only by the 6 h job default.
#
# Part 1 drives lib/run-split-chain.sh with the REAL `timeout`, the REAL
# transport and a stub `opencode` on PATH, using small floors so the split is
# exercised in seconds. Part 2 drives the REAL aggregate-reviews.sh end to end
# at its shipped 600 s default, through a PATH `timeout` shim that divides every
# duration by 100 — so the production split (390 s + remainder) runs as 3.9 s +
# remainder without the test taking ten minutes. Part 3 pins the wiring and the
# env-var contract (both workflow packagings).
#
# Offline; no network, no real opencode. Needs GNU `timeout` (fractional
# durations) for part 2.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
CHAIN="${SCRIPT_DIR}/lib/run-split-chain.sh"
AGG="${SCRIPT_DIR}/aggregate-reviews.sh"

TMP_DIR="$(mktemp -d /tmp/summary-timeout.XXXXXX)"
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "${TMP_DIR}"' EXIT

fail_count=0
check() { # check <label> <expected> <actual>
  if [ "$3" = "$2" ]; then
    echo "  ✅ $1"
  else
    echo "  ❌ $1 (expected '$2', got '$3')"
    fail_count=$((fail_count + 1))
  fi
}
has() { # has <file> <fixed-string> → 1/0
  if [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; then echo 1; else echo 0; fi
}

REAL_TIMEOUT="$(command -v timeout || true)"
if [ -z "$REAL_TIMEOUT" ]; then
  echo "❌ GNU timeout not found — cannot test a timeout"
  exit 1
fi

# --- The stub opencode ---------------------------------------------------------
# Records every call (model + epoch second). Models named in STUB_HANG never
# answer; models named in STUB_FAIL fail fast like a provider error; everyone
# else writes a summary long enough to pass aggregate-reviews.sh's 50-byte floor.
# The hang's fds point at /dev/null so an orphan could never hold a caller's pipe
# open — killing it is `timeout`'s job, not this harness's.
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/opencode" << 'STUB'
#!/bin/bash
cat > /dev/null
model=""
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$model" >> "${STUB_CALLS:-/dev/null}"
case " ${STUB_HANG:-} " in *" ${model} "*) exec sleep 120 < /dev/null > /dev/null 2>&1 ;; esac
case " ${STUB_FAIL:-} " in *" ${model} "*) echo "stub: provider error for ${model}" >&2; exit 1 ;; esac
cat << EOF
## 📋 Overall Summary
Summary written by ${model} for the timeout test. Padded past the transport's
200-byte floor (OPENCODE_MIN_OUTPUT_BYTES), which the summary call keeps: a
shorter answer is rejected as a silent provider failure before it gets here.

## 🎯 Recommendation
**Decision:** APPROVE
**Rationale:** stubbed

**MACHINE_READABLE_ACTION:** approve
EOF
STUB
chmod +x "${TMP_DIR}/bin/opencode"
printf 'summarise\n' > "${TMP_DIR}/prompt.txt"

# run_chain <case> <total> <primary> <secondary> — floors are 3 s / 2 s, so a
# 6 s total splits 4 + 2 and a 4 s total is too small to split.
run_chain() {
  local name="$1"; shift
  : > "${TMP_DIR}/${name}.calls"
  local started ended
  started=$(date +%s)
  PATH="${TMP_DIR}/bin:${PATH}" \
    STUB_CALLS="${TMP_DIR}/${name}.calls" \
    OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai \
    OPENCODE_MIN_OUTPUT_BYTES=1 \
    bash "$CHAIN" t "$1" 3 2 "$2" "$3" -- "${TMP_DIR}/prompt.txt" \
    > "${TMP_DIR}/${name}.out" 2> "${TMP_DIR}/${name}.err"
  echo "$?" > "${TMP_DIR}/${name}.rc"
  ended=$(date +%s)
  echo "$(( ended - started ))" > "${TMP_DIR}/${name}.secs"
}

echo "=========================================="
echo "Part 1: lib/run-split-chain.sh (real timeout)"
echo "=========================================="

# 1a. The case that cost the consumer runs: the primary hangs. It must be cut
# at its share and the fallback must get the rest — and answer.
STUB_HANG="openai/orch" run_chain hang 6 orch review
check "hung primary: the chain still succeeds" "0" "$(cat "${TMP_DIR}/hang.rc")"
check "hung primary: the answer is the fallback's" "1" \
  "$(has "${TMP_DIR}/hang.out" 'Summary written by openai/review')"
check "hung primary: the primary was tried first, then the fallback" \
  "openai/orch,openai/review" "$(paste -sd, "${TMP_DIR}/hang.calls")"
check "hung primary: the split is announced" "1" \
  "$(has "${TMP_DIR}/hang.err" 'budget 6s split: 4s for orch')"
check "hung primary: the timeout names the model and the limit" "1" \
  "$(grep -cE '^run-split-chain\.sh\[t\]: stage 1 \(orch\) timed out after [0-9]+s \(limit 4s\)$' "${TMP_DIR}/hang.err")"
check "hung primary: the hand-off is logged" "1" \
  "$(grep -cE 'handing the remaining [0-9]+s to review$' "${TMP_DIR}/hang.err")"
check "hung primary: the rescue is logged" "1" \
  "$(grep -cE 'rescued by review in [0-9]+s$' "${TMP_DIR}/hang.err")"
check "hung primary: bounded by the total, not the hang" "1" \
  "$([ "$(cat "${TMP_DIR}/hang.secs")" -le 8 ] && echo 1 || echo 0)"

# 1b. Both models hang: the chain must end at the TOTAL with 124, print nothing
# on stdout, and say which stage ran out.
STUB_HANG="openai/orch openai/review" run_chain both 6 orch review
check "both hang: exit 124 (timeout's own code)" "124" "$(cat "${TMP_DIR}/both.rc")"
check "both hang: nothing on stdout" "0" "$(wc -c < "${TMP_DIR}/both.out" | tr -d ' ')"
check "both hang: wall clock bounded by the 6s total" "1" \
  "$([ "$(cat "${TMP_DIR}/both.secs")" -le 8 ] && echo 1 || echo 0)"
check "both hang: stage 2 timeout named" "1" \
  "$(grep -cE 'stage 2 \(review\) timed out after [0-9]+s \(limit [0-9]+s\)$' "${TMP_DIR}/both.err")"

# 1c. A primary that fails FAST hands over nearly the whole budget, not the
# fixed reserve — the `total - elapsed` rule (LADR-081).
STUB_FAIL="openai/orch" run_chain fast 6 orch review
check "fast primary failure: the chain succeeds" "0" "$(cat "${TMP_DIR}/fast.rc")"
check "fast primary failure: reported as a failure, not a timeout" "1" \
  "$(grep -cE 'stage 1 \(orch\) failed \(rc 1\) after' "${TMP_DIR}/fast.err")"
check "fast primary failure: the fallback gets (nearly) the whole total" "1" \
  "$(grep -cE 'handing the remaining [56]s to review$' "${TMP_DIR}/fast.err")"
check "fast primary failure: the transport's own stderr is kept" "1" \
  "$(has "${TMP_DIR}/fast.err" 'stub: provider error for openai/orch')"

# 1d. Too small to split (4 s, floors 3 + 2): one bound around the whole chain,
# with the fallback carried IN-chain so a fast primary error still reaches it.
STUB_FAIL="openai/orch" run_chain small 4 orch review
check "unsplittable budget: announced as such" "1" \
  "$(has "${TMP_DIR}/small.err" 'budget 4s too small to split')"
check "unsplittable budget: the in-chain fallback still answers" "1" \
  "$(has "${TMP_DIR}/small.out" 'Summary written by openai/review')"

# 1e. A degenerate chain (fallback == primary, which is what LADR-066's failed
# orchestrator probe produces) gets the WHOLE budget — nobody to reserve for —
# and one call, not two.
STUB_HANG="openai/review" run_chain same 3 review review
check "degenerate chain: one model, whole budget" "1" \
  "$(has "${TMP_DIR}/same.err" 'budget 3s, single model review')"
check "degenerate chain: called once" "1" "$(wc -l < "${TMP_DIR}/same.calls" | tr -d ' ')"
check "degenerate chain: still bounded (124)" "124" "$(cat "${TMP_DIR}/same.rc")"

# 1f. A budget that is not a positive integer must never become `timeout 0s`
# (no limit) or an empty duration: refuse, and call nobody.
for _bad in abc 0 -5 ""; do
  : > "${TMP_DIR}/junk.calls"
  PATH="${TMP_DIR}/bin:${PATH}" STUB_CALLS="${TMP_DIR}/junk.calls" \
    bash "$CHAIN" t "$_bad" 3 2 orch review -- "${TMP_DIR}/prompt.txt" > /dev/null 2>&1
  _rc=$?
  check "junk total '${_bad}': refused with 64" "64" "$_rc"
  check "junk total '${_bad}': no model called" "0" "$(wc -l < "${TMP_DIR}/junk.calls" | tr -d ' ')"
done

echo ""
echo "=========================================="
echo "Part 2: aggregate-reviews.sh end to end (600s default, time scaled 1/100)"
echo "=========================================="

SANDBOX="${TMP_DIR}/repo"
mkdir -p "${SANDBOX}/.agents/skills/ai-review-report" "${TMP_DIR}/shim"
# The whole scripts tree, so the sandbox can never be missing a lib the real
# script needs (a missing lib fails the summary call and would make every
# assertion below test the fallback template by accident).
cp -R "${SCRIPT_DIR}" "${SANDBOX}/.agents/skills/ai-review-report/scripts"
cat > "${TMP_DIR}/shim/timeout" << SHIM
#!/bin/bash
# Divide the duration by 100 and hand off to the real timeout.
d="\${1%s}"; shift
printf '%s\n' "\$d" >> "\${TIMEOUT_LOG:-/dev/null}"
exec "${REAL_TIMEOUT}" "\$(awk -v d="\$d" 'BEGIN { printf "%.2f", d / 100 }')s" "\$@"
SHIM
chmod +x "${TMP_DIR}/shim/timeout"

# run_agg <case> [VAR=value ...] — runs the real aggregate-reviews.sh on one
# clean chunk review.
run_agg() {
  local name="$1"; shift
  rm -rf "${SANDBOX}/ci_temp"
  mkdir -p "${SANDBOX}/ci_temp/reviews"
  printf '### 📄 File: `src/a.cs`\n\n**Issues Found:**\n- None found.\n' \
    > "${SANDBOX}/ci_temp/reviews/chunk_0.md"
  : > "${TMP_DIR}/${name}.timeouts"
  local started ended
  started=$(date +%s)
  (
    cd "${SANDBOX}" || exit 1
    env PATH="${TMP_DIR}/shim:${TMP_DIR}/bin:${PATH}" \
      TIMEOUT_LOG="${TMP_DIR}/${name}.timeouts" \
      STUB_CALLS="${TMP_DIR}/${name}.calls" \
      OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai \
      OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=orch \
      OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS=0 \
      GITHUB_OUTPUT="${TMP_DIR}/${name}.gh" \
      "$@" \
      bash .agents/skills/ai-review-report/scripts/aggregate-reviews.sh \
        1 review full aaaaaaa1111 1 bbbbbbb2222 "test expertise" none
  ) > "${TMP_DIR}/${name}.log" 2>&1
  ended=$(date +%s)
  echo "$(( ended - started ))" > "${TMP_DIR}/${name}.secs"
  cp "${SANDBOX}/ci_temp/summary_stderr.log" "${TMP_DIR}/${name}.stderr" 2>/dev/null || true
  cp "${SANDBOX}/ci_temp/pr_summary.md" "${TMP_DIR}/${name}.summary" 2>/dev/null || true
}

# 2a. Hung orchestrator at the default budget: the review model rescues it.
run_agg rescue STUB_HANG=openai/orch
check "e2e hung orchestrator: default budget is 600s" "1" \
  "$(has "${TMP_DIR}/rescue.log" 'Summary budget: 600s across orch → review')"
check "e2e hung orchestrator: stage 1 bounded by the 390s share" "390" \
  "$(head -1 "${TMP_DIR}/rescue.timeouts")"
check "e2e hung orchestrator: stage 2 gets what is left of 600s" "1" \
  "$(sed -n 2p "${TMP_DIR}/rescue.timeouts" | awk '{ print ($1 >= 580 && $1 <= 600) ? 1 : 0 }')"
check "e2e hung orchestrator: the timeout is on the console, naming the model" "1" \
  "$(grep -cE 'summary: stage 1 \(orch\) timed out after [0-9]+s \(limit 390s\)' "${TMP_DIR}/rescue.log")"
check "e2e hung orchestrator: the rescue is on the console" "1" \
  "$(grep -cE 'summary: rescued by review in [0-9]+s' "${TMP_DIR}/rescue.log")"
check "e2e hung orchestrator: the summary is the fallback's" "1" \
  "$(has "${TMP_DIR}/rescue.summary" 'Summary written by openai/review')"
check "e2e hung orchestrator: agg_ok stays true" "1" \
  "$(has "${TMP_DIR}/rescue.log" 'PR summary generated successfully')"
check "e2e hung orchestrator: summary_stderr.log keeps the status lines" "1" \
  "$(has "${TMP_DIR}/rescue.stderr" 'run-split-chain.sh[summary]: stage 1 (orch) timed out')"

# 2b. Both hang: the call must END, agg_ok=false must fire, and the existing
# fallback template (REQUEST_CHANGES) must be what posts — a timeout never makes
# a review greener. With no merged findings LADR-085's sync cannot run, so the
# fail-closed action stands.
run_agg dead "STUB_HANG=openai/orch openai/review"
check "e2e both hang: aggregation finishes (bounded)" "1" \
  "$([ "$(cat "${TMP_DIR}/dead.secs")" -le 20 ] && echo 1 || echo 0)"
check "e2e both hang: logged as a timeout, not a generic failure" "1" \
  "$(has "${TMP_DIR}/dead.log" 'Summary generation timed out (600s budget, LADR-092)')"
check "e2e both hang: the fallback template is installed" "1" \
  "$(has "${TMP_DIR}/dead.summary" '**MACHINE_READABLE_ACTION:** REQUEST_CHANGES')"
check "e2e both hang: the posted overview says it timed out" "1" \
  "$(has "${TMP_DIR}/dead.summary" 'Summary generation timed out (600s budget;')"
check "e2e both hang: the review is fail-closed" "request_changes" \
  "$(grep '^review_action=' "${TMP_DIR}/dead.gh" 2>/dev/null | tail -1 | cut -d= -f2)"
check "e2e both hang: stage 2 timeout recorded in summary_stderr.log" "1" \
  "$(has "${TMP_DIR}/dead.stderr" 'stage 2 (review) timed out')"

# 2c. A fast provider error is NOT reported as a timeout.
run_agg apierr "STUB_FAIL=openai/orch openai/review"
check "e2e provider error: generic failure message, not a timeout" "1" \
  "$(has "${TMP_DIR}/apierr.log" 'Summary generation failed/empty - using fallback')"
check "e2e provider error: posted overview keeps the original wording" "1" \
  "$(has "${TMP_DIR}/apierr.summary" 'Summary generation encountered an error.')"

# 2d. A junk Variable falls back to the default rather than running unbounded.
run_agg junkvar OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT=10m
check "e2e junk Variable: warned" "1" \
  "$(has "${TMP_DIR}/junkvar.log" "OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT='10m' is not a positive integer")"
check "e2e junk Variable: default applied" "1" \
  "$(has "${TMP_DIR}/junkvar.log" 'Summary budget: 600s')"

echo ""
echo "=========================================="
echo "Part 3: wiring and env-var contract"
echo "=========================================="

check "aggregate-reviews.sh never calls the transport unbounded" "0" \
  "$(grep -c 'lib/opencode-with-fallback.sh"' "$AGG")"
check "the summary goes through the bounded chain with both models" "1" \
  "$(grep -c 'lib/run-split-chain.sh" summary "\$SUMMARY_TIMEOUT" .* "\$ORCHESTRATOR_MODEL_ID" "\$OPENCODE_MODEL_ID" -- ci_temp/summary_prompt.txt' "$AGG")"
check "a failed or timed-out chain still sets agg_ok=false" "1" \
  "$(grep 'lib/run-split-chain.sh" summary' "$AGG" | grep -c '|| { SUMMARY_RC=\$?; agg_ok=false; }')"
check "stderr still lands in ci_temp/summary_stderr.log" "1" \
  "$(grep 'lib/run-split-chain.sh" summary' "$AGG" | grep -c '2>ci_temp/summary_stderr.log')"
check "the runtime AGENTS.md cwd still reaches the transport (LADR-090)" "1" \
  "$(grep 'lib/run-split-chain.sh" summary' "$AGG" | grep -c '^OPENCODE_RUN_CWD="\$ORCH_RUN_CWD" ')"
check "the default budget is 600s" "1" "$(grep -c '^SUMMARY_TIMEOUT_DEFAULT=600$' "$AGG")"
check "the chain splits via the shared LADR-081 lib" "1" \
  "$(grep -c 'split-chunk-budget.sh" "\$_rsc_total" "\$_rsc_pmin" "\$_rsc_smin"' "$CHAIN")"
for _wf in .github/workflows/pipeline-code-review-report.yml .docs/examples/code-review-local.yml; do
  check "${_wf} declares OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT" "1" \
    "$(grep -c "OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT: \${{ vars.OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT || '600' }}" "${REPO_ROOT}/${_wf}")"
done
check "README documents OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT" "1" \
  "$([ "$(grep -c 'OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT' "${REPO_ROOT}/README.md")" -ge 1 ] && echo 1 || echo 0)"
check "SKILL.md documents OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT" "1" \
  "$([ "$(grep -c 'OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT' "${SCRIPT_DIR}/../SKILL.md")" -ge 1 ] && echo 1 || echo 0)"

echo ""
echo "=========================================="
if [ "$fail_count" -gt 0 ]; then
  echo "❌ Summary timeout tests failed: ${fail_count}"
  exit 1
fi
echo "✅ Summary timeout tests passed"
