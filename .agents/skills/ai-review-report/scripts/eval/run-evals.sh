#!/bin/bash
# run-evals.sh — LLM eval harness for the chunk-review model (the eval target).
#
# Scores the chunk-review LLM on two axes against a labeled corpus so that
# prompt / model / LADR changes can be regression-tested instead of being caught
# in production by adding yet another DR:
#
#   - PRECISION (must-not-flag): one+ fixture per DR-001…DR-014. The reviewer
#     must NOT re-raise a known false positive at Critical/High/Medium
#     (Low/none is allowed). ANY such flag fails the run — zero tolerance,
#     because every DR is a *confirmed* false positive with a real PR reference.
#   - RECALL (must-catch): fixtures with a seeded real defect the reviewer SHOULD
#     flag at >= its labeled severity. The run fails if the catch rate drops
#     below EVAL_RECALL_THRESHOLD.
#
# It drives the REAL review-in-chunks.sh per fixture (the genuine eval target —
# prompt assembly + the two-tier opencode chain), so prompt/LADR edits are
# regression-tested, not reimplemented. Transport is reused verbatim: the same
# lib/resolve-provider.sh + lib/opencode-with-fallback.sh + setup-opencode-config.sh
# + opencode-health.sh the gate and local-review.sh use. NO new model transport.
#
# *** MAKES REAL, PAID MODEL CALLS. Opt-in only — never in the default test path. ***
# Run locally via eval/local-evals.sh (handles cred harvest + macOS timeout shim)
# or in CI via the workflow_dispatch-only .github/workflows/llm-eval-harness.yml.
#
# Environment (provider/model — the SAME designed-model config the gate uses,
# resolved exactly like CI via lib/resolve-provider.sh, LADR-026/027):
#   OPENCODE_REVIEW_REPORT_PROVIDER          GEMINI (default) | COPILOT | OPENAI |
#                                            OPENCODE-GO-OPENAI | OPENCODE-GO-ANTHROPIC
#   OPENCODE_REVIEW_REPORT_MODEL_PRIMARY     required — the chunk-review model under eval
#   OPENCODE_REVIEW_REPORT_MODEL_SECONDARY / OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR
#                                            fallback / non-analytical model (default: the
#                                            designed PRIMARY model — see below)
#   plus the selected provider's OPENCODE_REVIEW_REPORT_<P>_URL (Variable) +
#   OPENCODE_<P>_API_KEY (Secret) — validated by the resolver. These are the same
#   GitHub Variables/Secrets that define the gate's models, so the eval tests the
#   designed models, not a hardcoded chain.
#
# Eval config:
#   EVAL_RECALL_THRESHOLD   min must-catch catch-rate %% to pass        (default 80)
#   EVAL_SAMPLES            runs per fixture; precision fails if flagged in ANY
#                           sample, recall passes if caught in a MAJORITY (default 1)
#   EVAL_CORPUS_DIR         corpus root override                  (default ./corpus)
#   EVAL_FILTER             only run fixtures whose id matches this substring
#
# Exit: 0 if precision is perfect AND recall >= threshold; non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_SCRIPTS_DIR/../../../.." && pwd)"

REVIEW_SCRIPT="$SKILL_SCRIPTS_DIR/review-in-chunks.sh"
SCORE_SCRIPT="$SCRIPT_DIR/lib/score-review.sh"
CORPUS_DIR="${EVAL_CORPUS_DIR:-$SCRIPT_DIR/corpus}"
# Resolve to an absolute path: run_fixture does `cd "$sandbox"` before copying
# fixture content, so a relative corpus path would break the copy.
[ -d "$CORPUS_DIR" ] && CORPUS_DIR="$(cd "$CORPUS_DIR" && pwd)"

# Canonical DR-standards context the reviewer reads in production (LADR-003 /
# MANDATORY_CONTEXT_FILES). DR-001…011 are the real instructions file; DR-012…014
# come from the SKILL.md Key Behaviors, mirrored in the corpus supplement. Both
# are placed at their PRODUCTION dot-paths in each sandbox so review-in-chunks.sh
# always includes them (it auto-includes dot-prefixed/root context — line ~371).
DR_INSTRUCTIONS_SRC="$REPO_ROOT/.github/instructions/code-review-standards.instructions.md"
DR_SUPPLEMENT_SRC="$CORPUS_DIR/context/code-review-standards-supplement.md"
DR_INSTRUCTIONS_DEST=".github/instructions/code-review-standards.instructions.md"
DR_SUPPLEMENT_DEST=".agents/skills/code-review-standards/SKILL.md"

EVAL_RECALL_THRESHOLD="${EVAL_RECALL_THRESHOLD:-80}"
EVAL_SAMPLES="${EVAL_SAMPLES:-1}"
EVAL_FILTER="${EVAL_FILTER:-}"

EXPERTISE_STATEMENT="You are a principal software engineer performing a rigorous \
pull-request code review. You apply the project's documented code-review standards \
and intentional design decisions, and you do not raise findings the standards mark \
as intentional. You flag genuine correctness, security, and data-safety defects in \
changed code at the appropriate severity."

die() { echo "❌ $*" >&2; exit 1; }

# EVAL_SELFTEST=1 is a TEST-ONLY seam used by test-evals.sh: it bypasses the
# real model call + provider/health preflight and instead scores a canned
# review (fixture-dir/selftest-review.md), so the corpus walk, per-fixture
# verdict, precision/recall aggregation, threshold gating, and exit code can be
# regression-tested WITHOUT any paid call. It never affects a real run.
SELFTEST="${EVAL_SELFTEST:-0}"

# ---------------------------------------------------------------------------
# Preflight: validate the harness can actually run.
# ---------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "jq not found (required to parse fixture manifests)."
command -v git >/dev/null 2>&1 || die "git not found."
[ -f "$SCORE_SCRIPT" ] || die "score-review.sh not found at $SCORE_SCRIPT."
[ -d "$CORPUS_DIR" ]   || die "corpus dir not found at $CORPUS_DIR."

if [ "$SELFTEST" != "1" ]; then
  command -v opencode >/dev/null 2>&1 || die "opencode CLI not found (install: curl -fsSL https://opencode.ai/install | bash)."
  command -v timeout  >/dev/null 2>&1 || die "timeout not found (run via eval/local-evals.sh on macOS — it installs a shim)."
  [ -f "$REVIEW_SCRIPT" ] || die "review-in-chunks.sh not found at $REVIEW_SCRIPT (workflow↔script path coupling)."
  [ -f "$DR_INSTRUCTIONS_SRC" ] || die "DR standards not found at $DR_INSTRUCTIONS_SRC."
  [ -f "$DR_SUPPLEMENT_SRC" ]   || die "DR supplement not found at $DR_SUPPLEMENT_SRC."
  [ -n "${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-}" ] || die "OPENCODE_REVIEW_REPORT_MODEL_PRIMARY is unset — set the chunk-review model under eval (the OPENCODE_REVIEW_REPORT_MODEL_PRIMARY Variable, or --model via local-evals.sh / the CI workflow)."

  # Default the rest of the chain to the designed PRIMARY model (NOT a hardcoded
  # Gemini id): keeps a non-GEMINI provider's chain same-family so the resolver
  # does not abort, and means the eval never silently tests a model the deployment
  # did not design. An explicit OPENCODE_REVIEW_REPORT_MODEL_SECONDARY /
  # _ORCHESTRATOR Variable still wins.
  export OPENCODE_REVIEW_REPORT_MODEL_SECONDARY="${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY}"
  export OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR="${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY}"

  # Resolve provider → provider-id + creds (fails fast on bad creds / model chain),
  # then install the managed opencode.json and run the provider-agnostic health
  # check — the exact preflight the gate and local-review.sh use (LADR-026/028).
  # shellcheck source=../lib/resolve-provider.sh
  source "$SKILL_SCRIPTS_DIR/lib/resolve-provider.sh"
  bash "$SKILL_SCRIPTS_DIR/lib/setup-opencode-config.sh"
  bash "$SKILL_SCRIPTS_DIR/lib/opencode-health.sh" || die "opencode health check failed — cannot run evals."
fi

echo "=========================================="
echo " LLM Eval Harness — chunk-review model"
echo "=========================================="
echo "Provider : ${OPENCODE_REVIEW_REPORT_PROVIDER:-(selftest)} (id: ${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-?})"
echo "Model    : ${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-(selftest)} (fallback: ${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-})"
echo "Corpus   : $CORPUS_DIR"
echo "Samples  : $EVAL_SAMPLES | Recall threshold: ${EVAL_RECALL_THRESHOLD}%"
[ -n "$EVAL_FILTER" ] && echo "Filter   : $EVAL_FILTER"
echo ""

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/llm-evals.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

# ---------------------------------------------------------------------------
# run_fixture <manifest-path>
# Sets up a sandbox git repo (before -> head), runs the REAL chunk review with
# the DR context in place, scores it, and echoes "SEVERITY1,SEVERITY2,..." (or
# the empty string) — the set of blocking severities the reviewer raised.
# Returns non-zero only on an infrastructure failure (so the caller can abort).
# ---------------------------------------------------------------------------
run_fixture() {
  local manifest="$1"
  local fdir; fdir="$(dirname "$manifest")"

  # Self-test seam: score a canned review instead of calling the model.
  if [ "$SELFTEST" = "1" ]; then
    local canned="$fdir/selftest-review.md"
    [ -f "$canned" ] || { echo "__INFRA_FAIL__"; return 1; }
    local sevs; sevs="$(bash "$SCORE_SCRIPT" "$canned" | paste -sd, -)"
    echo "$canned|$sevs"
    return 0
  fi

  local sandbox; sandbox="$(mktemp -d "$WORK_ROOT/fixture.XXXXXX")"

  (
    cd "$sandbox" || exit 90
    git init -q
    git config user.email "eval@example.com"
    git config user.name  "Eval Harness"

    # Base commit: the "before" tree (empty -> all "after" files are net-new and
    # thus fully reviewable as changed code, which is what we want for new-file
    # fixtures). before/ is optional and used for modify/delete fixtures.
    if [ -d "$fdir/before" ] && [ -n "$(ls -A "$fdir/before" 2>/dev/null)" ]; then
      cp -R "$fdir/before/." .
      git add -A
      git commit -q -m "base" --allow-empty
    else
      git commit -q -m "base" --allow-empty
    fi
    local from_sha; from_sha="$(git rev-parse HEAD)"

    # Head commit: overlay the "after" tree. Any path present in before/ but not
    # in after/ is a deletion (handled by syncing the working tree to after/).
    if [ -d "$fdir/before" ]; then
      # Reset tracked content to exactly the after/ tree (adds, modifies, deletes).
      git rm -rq --ignore-unmatch . >/dev/null 2>&1 || true
    fi
    cp -R "$fdir/after/." .
    git add -A
    git commit -q -m "head" --allow-empty
    local to_sha; to_sha="$(git rev-parse HEAD)"

    # Place the DR-standards context at its production dot-paths so the reviewer
    # reads the SAME standards production injects via MANDATORY_CONTEXT_FILES.
    mkdir -p "$(dirname "$DR_INSTRUCTIONS_DEST")" "$(dirname "$DR_SUPPLEMENT_DEST")"
    cp "$DR_INSTRUCTIONS_SRC" "$DR_INSTRUCTIONS_DEST"
    cp "$DR_SUPPLEMENT_SRC"   "$DR_SUPPLEMENT_DEST"

    mkdir -p ci_temp ci_temp/reviews
    git diff --name-only -z "$from_sha..$to_sha" > ci_temp/changed_files.txt
    printf '%s\n%s\n' "$DR_INSTRUCTIONS_DEST" "$DR_SUPPLEMENT_DEST" > ci_temp/context_files.txt

    export OPENCODE_MODEL_ID="$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY"
    export GITHUB_OUTPUT="$sandbox/ci_temp/github_output.txt"
    : > "$GITHUB_OUTPUT"

    # The genuine eval target: real prompt assembly + the two-tier opencode chain.
    bash "$REVIEW_SCRIPT" "$from_sha" "$to_sha" "$OPENCODE_MODEL_ID" "$EXPERTISE_STATEMENT" \
      >"$sandbox/ci_temp/review_run.log" 2>&1 || true
  )
  local rc=$?
  [ "$rc" -eq 90 ] && { echo "__INFRA_FAIL__"; rm -rf "$sandbox"; return 1; }

  # Concatenate all chunk reviews (tiny fixtures -> 1 chunk, but be robust).
  local review_md="$sandbox/ci_temp/review_all.md"
  cat "$sandbox"/ci_temp/reviews/chunk_*.md > "$review_md" 2>/dev/null || true
  if [ ! -s "$review_md" ]; then
    # No review produced at all — surface the run log for diagnosis.
    echo "__INFRA_FAIL__"
    cp "$sandbox/ci_temp/review_run.log" "$WORK_ROOT/$(basename "$fdir").lastlog" 2>/dev/null || true
    rm -rf "$sandbox"
    return 1
  fi

  local sevs; sevs="$(bash "$SCORE_SCRIPT" "$review_md" | paste -sd, -)"
  # Keep the review around for the caller to optionally archive on failure.
  echo "$review_md|$sevs"
  return 0
}

# ---------------------------------------------------------------------------
# Drive the corpus.
# ---------------------------------------------------------------------------
declare -a RESULTS=()          # "kind|id|verdict|detail"
precision_total=0; precision_fail=0
recall_total=0;    recall_caught=0
infra_fail=0

majority() { echo $(( ($1 / 2) + 1 )); }

shopt -s nullglob
manifests=( "$CORPUS_DIR"/must-not-flag/*/manifest.json "$CORPUS_DIR"/must-catch/*/manifest.json )
shopt -u nullglob
[ "${#manifests[@]}" -gt 0 ] || die "no fixtures found under $CORPUS_DIR/{must-not-flag,must-catch}."

for manifest in "${manifests[@]}"; do
  id="$(jq -r '.id' "$manifest")"
  kind="$(jq -r '.kind' "$manifest")"
  label="$(jq -r '.label // .id' "$manifest")"
  min_sev="$(jq -r '.min_severity // "HIGH"' "$manifest" | tr '[:lower:]' '[:upper:]')"

  if [ -n "$EVAL_FILTER" ] && [[ "$id" != *"$EVAL_FILTER"* ]]; then
    continue
  fi

  echo "▶ [$kind] $id ($label)"

  # Run EVAL_SAMPLES times; collect the blocking-severity set from each sample.
  flagged_any=false           # precision: did ANY sample flag Crit/High/Med?
  caught_count=0              # recall: how many samples caught >= min_sev?
  sample_infra_fail=false
  for ((s=1; s<=EVAL_SAMPLES; s++)); do
    out="$(run_fixture "$manifest")" || { sample_infra_fail=true; break; }
    if [ "$out" = "__INFRA_FAIL__" ]; then sample_infra_fail=true; break; fi
    sevs="${out#*|}"          # e.g. "HIGH,MEDIUM" or ""

    # precision: any of CRITICAL/HIGH/MEDIUM present is a re-raised false positive
    if printf '%s' "$sevs" | grep -qE '(CRITICAL|HIGH|MEDIUM)'; then
      flagged_any=true
    fi
    # recall: caught if a flag at >= min_sev is present
    case "$min_sev" in
      CRITICAL) printf '%s' "$sevs" | grep -q 'CRITICAL' && caught_count=$((caught_count+1)) ;;
      *)        printf '%s' "$sevs" | grep -qE '(CRITICAL|HIGH)' && caught_count=$((caught_count+1)) ;;
    esac
    [ "$EVAL_SAMPLES" -gt 1 ] && echo "    sample $s/$EVAL_SAMPLES: [${sevs:-clean}]"
  done

  if [ "$sample_infra_fail" = true ]; then
    infra_fail=$((infra_fail+1))
    RESULTS+=("$kind|$id|INFRA|model/run failure — see logs in $WORK_ROOT")
    echo "    ⚠️  INFRA FAILURE (no usable review)"
    continue
  fi

  if [ "$kind" = "must-not-flag" ]; then
    precision_total=$((precision_total+1))
    if [ "$flagged_any" = true ]; then
      precision_fail=$((precision_fail+1))
      RESULTS+=("$kind|$id|FAIL|re-raised a known false positive (DR regression)")
      echo "    ❌ FAIL — re-raised $label at Critical/High/Medium"
    else
      RESULTS+=("$kind|$id|PASS|did not re-raise")
      echo "    ✅ PASS"
    fi
  else
    recall_total=$((recall_total+1))
    need=$(majority "$EVAL_SAMPLES")
    if [ "$caught_count" -ge "$need" ]; then
      recall_caught=$((recall_caught+1))
      RESULTS+=("$kind|$id|PASS|caught seeded defect (>= $min_sev) in $caught_count/$EVAL_SAMPLES")
      echo "    ✅ PASS — caught >= $min_sev ($caught_count/$EVAL_SAMPLES)"
    else
      RESULTS+=("$kind|$id|FAIL|missed seeded defect ($caught_count/$EVAL_SAMPLES caught, need $need)")
      echo "    ❌ FAIL — missed seeded defect ($caught_count/$EVAL_SAMPLES)"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Report + gate.
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " RESULTS"
echo "=========================================="
printf '%-14s %-34s %-6s %s\n' "KIND" "FIXTURE" "RESULT" "DETAIL"
printf '%-14s %-34s %-6s %s\n' "----" "-------" "------" "------"
# Guard the expansion: macOS bash 3.2 errors on "${arr[@]}" for an empty array
# under `set -u` (e.g. EVAL_FILTER matched nothing).
if [ "${#RESULTS[@]}" -gt 0 ]; then
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r k id verdict detail <<< "$r"
    printf '%-14s %-34s %-6s %s\n' "$k" "$id" "$verdict" "$detail"
  done
else
  echo "(no fixtures ran${EVAL_FILTER:+ — filter '$EVAL_FILTER' matched none})"
fi

precision_pass=$((precision_total - precision_fail))
recall_rate=0
[ "$recall_total" -gt 0 ] && recall_rate=$(( recall_caught * 100 / recall_total ))
precision_rate=100
[ "$precision_total" -gt 0 ] && precision_rate=$(( precision_pass * 100 / precision_total ))

echo ""
echo "------------------------------------------"
echo " Precision (must-not-flag): $precision_pass/$precision_total clean (${precision_rate}%)  [zero-tolerance]"
echo " Recall    (must-catch)   : $recall_caught/$recall_total caught (${recall_rate}%)  [threshold ${EVAL_RECALL_THRESHOLD}%]"
[ "$infra_fail" -gt 0 ] && echo " Infra failures           : $infra_fail (counted as run failure)"
echo "------------------------------------------"

fail=0
if [ "$precision_fail" -gt 0 ]; then
  echo "❌ PRECISION REGRESSION: $precision_fail known false positive(s) re-raised at Critical/High/Medium."
  fail=1
fi
if [ "$recall_total" -gt 0 ] && [ "$recall_rate" -lt "$EVAL_RECALL_THRESHOLD" ]; then
  echo "❌ RECALL REGRESSION: catch rate ${recall_rate}% below threshold ${EVAL_RECALL_THRESHOLD}%."
  fail=1
fi
if [ "$infra_fail" -gt 0 ]; then
  echo "❌ INFRA FAILURE: $infra_fail fixture(s) produced no usable review (model/transport)."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✅ EVAL PASSED — no precision regressions, recall above threshold."
else
  echo "🛑 EVAL FAILED."
fi
exit "$fail"
