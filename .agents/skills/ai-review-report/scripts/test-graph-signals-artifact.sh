#!/bin/bash
# test-graph-signals-artifact.sh — the run-artifact contract for LADR-050.
#
# Phase 2a's promise is narrow and easy to break silently: when the slice ran,
# ci_temp/run/graph/graph_review_signals.tsv ships and metadata.json says so;
# when it did not, nothing extra is uploaded and nothing lies.
#
# The function is EXTRACTED from run-review.sh and executed, not reimplemented.
# A copy of the logic in the test would keep passing after the real one was
# edited — which is the failure mode this suite exists to prevent. Extraction
# skips the metadata heredoc before finding the function closing brace.
#
# Requires Bash >= 4 (the trap body uses ${var,,}).

set -eo pipefail

if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "❌ Requires Bash >= 4 (found ${BASH_VERSION:-unknown})." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_REVIEW="$SCRIPT_DIR/run-review.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

WORK_DIR="ci_temp"
RUN_DIR="${WORK_DIR}/run"

# The real function, verbatim.
#
# Extraction cannot just stop at the first `^}`: the metadata heredoc contains a
# JSON document whose closing brace also sits at column 0, so that heuristic
# cuts the function off mid-heredoc. Anchor on the heredoc marker instead — the
# function's own `}` is the first one AFTER `METADATA_EOF`.
_start="$(grep -n '^assemble_run_artifacts() {' "$RUN_REVIEW" | head -n1 | cut -d: -f1)"
_heredoc="$(grep -n '^METADATA_EOF$' "$RUN_REVIEW" | head -n1 | cut -d: -f1)"
_end="$(awk -v h="${_heredoc:-0}" 'NR > h && /^\}$/ { print NR; exit }' "$RUN_REVIEW")"
if [ -z "${_start:-}" ] || [ -z "${_end:-}" ]; then
  echo "❌ could not locate assemble_run_artifacts() in run-review.sh (start=${_start:-none} end=${_end:-none})" >&2
  exit 1
fi
sed -n "${_start},${_end}p" "$RUN_REVIEW" > "${TMP_DIR}/assemble.sh"
if ! grep -q '^  return 0$' "${TMP_DIR}/assemble.sh"; then
  echo "❌ assemble_run_artifacts() extraction looks truncated — update this test's anchor" >&2
  tail -3 "${TMP_DIR}/assemble.sh" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${TMP_DIR}/assemble.sh"

reset_sandbox() {
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  : > "${TMP_DIR}/github_output"
  GITHUB_OUTPUT="${TMP_DIR}/github_output"
  GRAPH_ANALYSIS_AVAILABLE=true
}

seed_signals() {
  printf 'src/a.cs\t10\t20\tAlpha\t0.85\ttrue\n' > "${WORK_DIR}/graph_review_signals.tsv"
  printf '`src/a.cs:10` Alpha — risk 0.85\n' > "${WORK_DIR}/chunk_0_graph_signals.md"
}

cd "$TMP_DIR"

# ── 1. Flag on, signals present ──────────────────────────────────────────────
reset_sandbox
seed_signals
OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS=1
OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=1
assemble_run_artifacts || true

if [ -f "${RUN_DIR}/graph/graph_review_signals.tsv" ]; then
  ok "the signals TSV ships when the flag is on and the file exists"
else
  bad "the signals TSV did not ship (flag on, file present)"
  ls -R "$RUN_DIR" 2>/dev/null | sed 's/^/       /'
fi

meta="${RUN_DIR}/metadata.json"
if jq -e '.graph_signals == true and .graph_signals_chunks == 1 and .graph_analysis_available == "true"' "$meta" > /dev/null; then
  ok "metadata.json records graph_signals=true"
else
  bad "metadata.json does not record graph_signals=true"
  [ -f "$meta" ] && sed 's/^/       /' "$meta"
fi

# The shipped copy must be the real bytes, not a truncated or re-rendered one.
if cmp -s "${WORK_DIR}/graph_review_signals.tsv" "${RUN_DIR}/graph/graph_review_signals.tsv"; then
  ok "the shipped TSV is byte-identical to the produced one"
else
  bad "the shipped TSV differs from the produced one"
fi

# ── 2. Flag off, signals present ─────────────────────────────────────────────
# The data is on disk but the feature is dark: shipping it would imply to a
# consumer that the chunk was told something it was not.
reset_sandbox
seed_signals
OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS=1
OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=0
assemble_run_artifacts || true

if [ ! -e "${RUN_DIR}/graph/graph_review_signals.tsv" ]; then
  ok "nothing ships when the flag is off, even with the file present"
else
  bad "the TSV shipped although the flag is off — it would imply an enrichment that never ran"
fi
if [ -f "$meta" ] && grep -q '"graph_signals": false' "$meta"; then
  ok "metadata.json records graph_signals=false"
else
  bad "metadata.json does not record graph_signals=false"
fi

# ── 3. Flag on, no signals file (graph never ran) ────────────────────────────
reset_sandbox
OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS=1
OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=1
assemble_run_artifacts || true

if [ ! -e "${RUN_DIR}/graph" ]; then
  ok "no graph/ directory is created when there were no signals"
else
  bad "an empty graph/ directory was created — a consumer would look for a file that is not there"
fi
if [ -f "$meta" ] && grep -q '"graph_signals": false' "$meta"; then
  ok "metadata.json records no rendered slice"
else
  bad "metadata.json does not record graph_signals=false for the no-signals case"
fi

# ── 4. Artifact assembly never decides the run ───────────────────────────────
# LADR-062's trap contract: the best-effort copy must not change the exit status
# the caller reports. A failing `cp` inside the function must not, either.
reset_sandbox
seed_signals
mkdir -p "${RUN_DIR}/graph/graph_review_signals.tsv"   # a directory where a file goes
OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS=1
OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=1
set +e
( assemble_run_artifacts )
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "a failed graph copy leaves the assembler's exit status at 0"
else
  bad "a failed graph copy changed the assembler's exit status (rc=${rc})"
fi
if jq -e '.graph_signals == false' "$meta" > /dev/null; then
  ok "failed copy does not claim a shipped artifact"
else
  bad "failed copy still claims graph_signals=true"
fi

# A producer file is not proof that any chunk used it: all rows could have
# been excluded from the review. Likewise stale data must not override a graph
# that was explicitly disabled or failed this run.
for state in no-slice failed disabled; do
  reset_sandbox
  seed_signals
  OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=1
  case "$state" in
    no-slice) rm "${WORK_DIR}/chunk_0_graph_signals.md" ;;
    *) GRAPH_ANALYSIS_AVAILABLE="$state" ;;
  esac
  assemble_run_artifacts
  if jq -e '.graph_signals == false' "$meta" > /dev/null && [ ! -e "${RUN_DIR}/graph" ]; then
    ok "$state: no false enrichment or graph upload"
  else
    bad "$state: metadata or uploaded files claim unused enrichment"
  fi
done

# Exercise the actual EXIT trap in a fresh shell, so a success return from the
# assembler cannot overwrite the failing run's original exit code.
reset_sandbox
seed_signals
mkdir -p "${RUN_DIR}/graph/graph_review_signals.tsv"
{
  printf '#!/bin/bash\nset -euo pipefail\n'
  printf 'source "%s"\nWORK_DIR="%s/ci_temp"\nGITHUB_OUTPUT="%s/github_output"\n' "$TMP_DIR/assemble.sh" "$TMP_DIR" "$TMP_DIR"
  printf 'OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS=1\nGRAPH_ANALYSIS_AVAILABLE=true\n'
  grep '^trap .*assemble_run_artifacts; exit' "$RUN_REVIEW"
  printf 'exit 37\n'
} > "$TMP_DIR/trap-test.sh"
rc=0
bash "$TMP_DIR/trap-test.sh" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 37 ]; then ok 'real EXIT trap preserves exit 37'; else bad "EXIT trap changed exit 37 to $rc"; fi

# ── 5. The truthy test matches the rest of the pipeline ─────────────────────
# Same tokenized test as LADR-049 and as review-in-chunks.sh's own gate, so a
# value cannot mean "on" in the artifact and "off" in the prompt. Note what this
# tokenization does NOT accept: "1true" is FALSY here, because no separator
# splits it into a known token. That is the repo-wide convention, not a quirk
# of this copy — the assertion below pins it so a future "fix" that special-cases
# it fails instead of silently diverging from the prompt gate.
reset_sandbox
seed_signals
unset OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS
assemble_run_artifacts
if jq -e '.graph_signals == true' "$meta" > /dev/null; then
  ok 'unset flag enables graph artifacts by default'
else
  bad 'unset flag did not enable graph artifacts'
fi

for v in "" true YES on " yes "; do
  reset_sandbox
  seed_signals
  OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS=1
  OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS="$v"
  assemble_run_artifacts >/dev/null 2>&1 || true
  if [ -f "${RUN_DIR}/graph/graph_review_signals.tsv" ]; then
    ok "'${v}' enables the graph copy"
  else
    bad "'${v}' should enable the graph copy"
  fi
done

for v in 0 false no off 1true; do
  reset_sandbox
  seed_signals
  OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS=1
  OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS="$v"
  assemble_run_artifacts >/dev/null 2>&1 || true
  if [ ! -e "${RUN_DIR}/graph/graph_review_signals.tsv" ]; then
    ok "'${v}' leaves the graph copy off"
  else
    bad "'${v}' should leave the graph copy off (tokenized truthy test)"
  fi
done

# ── 6. Both packagings declare the flag ──────────────────────────────────────
# The repo rule: a new Variable the entrypoint reads must be in both env blocks
# in the same commit, or the local-job packaging silently runs the old default.
for wf in "${REPO_ROOT}/.github/workflows/pipeline-code-review-report.yml" \
          "${REPO_ROOT}/.docs/examples/code-review-local.yml"; do
  name="$(basename "$wf")"
  if grep -q "OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS:.*|| '1'" "$wf"; then
    ok "${name} declares default-on OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS"
  else
    bad "${name} does not declare OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS (packaging parity)"
  fi
  if grep -q "OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES:.*'1024'" "$wf"; then
    ok "${name} declares the 1024-byte cap"
  else
    bad "${name} omits or changes the cap default"
  fi
done

cache_key() { grep -F 'key: crg-${{ runner.os }}-' "$1" | sed 's/^[[:space:]]*//'; }
if [ "$(cache_key "$REPO_ROOT/.github/workflows/pipeline-code-review-report.yml")" = \
     "$(cache_key "$REPO_ROOT/.docs/examples/code-review-local.yml")" ]; then
  ok 'graph cache keys match across both packagings'
else
  bad 'graph cache keys drift between packagings'
fi

# ── 7. The README documents both new Variables ───────────────────────────────
for var in OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS OPENCODE_REVIEW_REPORT_GRAPH_SIGNALS_MAX_BYTES; do
  if grep -q "$var" "${REPO_ROOT}/README.md"; then
    ok "README documents ${var}"
  else
    bad "README does not document ${var}"
  fi
done

echo ""
echo "=========================================="
echo "Results: ${pass} passed, ${fail} failed"
echo "=========================================="
[ "$fail" -eq 0 ]
