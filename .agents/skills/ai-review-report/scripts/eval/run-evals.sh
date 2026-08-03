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
#                                            ANTHROPIC | OPENCODE-GO-OPENAI |
#                                            OPENCODE-GO-ANTHROPIC | OPEN_ROUTER
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
# MANDATORY_CONTEXT_FILES). The eval corpus carries a self-contained DR-001...011
# snapshot because this repo retired its old `.github/instructions` tree; the
# DR-012...015 supplement mirrors the ai-review-report SKILL.md Key Behaviors.
# Both are assembled into the production context path in each sandbox.
DR_STANDARDS_BASE_SRC="$CORPUS_DIR/context/code-review-standards.md"
DR_SUPPLEMENT_SRC="$CORPUS_DIR/context/code-review-standards-supplement.md"
DR_STANDARDS_DEST=".agents/skills/code-review-standards/SKILL.md"

EVAL_RECALL_THRESHOLD="${EVAL_RECALL_THRESHOLD:-80}"
EVAL_SAMPLES="${EVAL_SAMPLES:-1}"
EVAL_FILTER="${EVAL_FILTER:-}"
# Optional triage archive: when set, each fixture's concatenated review markdown
# is copied to "$EVAL_ARTIFACT_DIR/<id>.review.md" (and infra-fail run logs to
# "<fixture>.lastlog"). The per-fixture sandbox + WORK_ROOT are wiped on exit, so
# without this a precision FAIL leaves no trace of WHAT the model flagged — the
# CI workflow sets this and uploads the dir so failures are inspectable.
EVAL_ARTIFACT_DIR="${EVAL_ARTIFACT_DIR:-}"
[ -n "$EVAL_ARTIFACT_DIR" ] && mkdir -p "$EVAL_ARTIFACT_DIR" 2>/dev/null || true

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
  [ -f "$DR_STANDARDS_BASE_SRC" ] || die "DR standards not found at $DR_STANDARDS_BASE_SRC."
  [ -f "$DR_SUPPLEMENT_SRC" ]     || die "DR supplement not found at $DR_SUPPLEMENT_SRC."
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

    # Place the DR-standards context at its production dot-path so the reviewer
    # reads the same standards production injects via MANDATORY_CONTEXT_FILES.
    mkdir -p "$(dirname "$DR_STANDARDS_DEST")"
    {
      cat "$DR_STANDARDS_BASE_SRC"
      printf '\n\n'
      cat "$DR_SUPPLEMENT_SRC"
    } > "$DR_STANDARDS_DEST"

    mkdir -p ci_temp ci_temp/reviews
    git diff --name-only -z "$from_sha..$to_sha" > ci_temp/changed_files.txt
    printf '%s\n' "$DR_STANDARDS_DEST" > ci_temp/context_files.txt

    export OPENCODE_MODEL_ID="$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY"
    export GITHUB_OUTPUT="$sandbox/ci_temp/github_output.txt"
    : > "$GITHUB_OUTPUT"

    # The genuine eval target: real prompt assembly + the two-tier opencode chain.
    bash "$REVIEW_SCRIPT" "$from_sha" "$to_sha" "$OPENCODE_MODEL_ID" "$EXPERTISE_STATEMENT" \
      >"$sandbox/ci_temp/review_run.log" 2>&1 || true
  )
  local rc=$?
  [ "$rc" -eq 90 ] && { echo "__INFRA_FAIL__"; rm -rf "$sandbox"; return 1; }

  # A chunk that failed to review is NOT a clean review. review-in-chunks.sh
  # writes a NON-EMPTY stub on model failure ("## ⚠️ Review Failed for Chunk …
  # all fallbacks exhausted") and drops a LADR-031 flag file beside it, so the
  # emptiness check below never fires and the stub used to be scored like any
  # other review: no [VERIFIED] findings, therefore "clean".
  #
  # That is a silent pass of the worst kind. On run 30791708130 the provider was
  # down for the whole run, every one of the 20 fixtures got the stub, and the
  # harness reported **precision 14/14 (100%)** while having reviewed exactly
  # nothing. Only the recall half — 0/6 — made the outage visible at all; a
  # precision-only corpus would have gone green.
  #
  # Detection is flag-file existence ONLY, never a grep for the stub text: that
  # is LADR-031's rule, and it exists because a quoted marker inside a real
  # review false-matched once already.
  if compgen -G "$sandbox/ci_temp/reviews/chunk_*.failed" >/dev/null 2>&1; then
    echo "__INFRA_FAIL__"
    cp "$sandbox/ci_temp/review_run.log" "$WORK_ROOT/$(basename "$fdir").lastlog" 2>/dev/null || true
    [ -n "${EVAL_ARTIFACT_DIR:-}" ] && cp "$sandbox/ci_temp/review_run.log" "$EVAL_ARTIFACT_DIR/$(basename "$fdir").lastlog" 2>/dev/null || true
    rm -rf "$sandbox"
    return 1
  fi

  # Concatenate all chunk reviews (tiny fixtures -> 1 chunk, but be robust).
  local review_md="$sandbox/ci_temp/review_all.md"
  cat "$sandbox"/ci_temp/reviews/chunk_*.md > "$review_md" 2>/dev/null || true
  if [ ! -s "$review_md" ]; then
    # No review produced at all — surface the run log for diagnosis.
    echo "__INFRA_FAIL__"
    cp "$sandbox/ci_temp/review_run.log" "$WORK_ROOT/$(basename "$fdir").lastlog" 2>/dev/null || true
    [ -n "${EVAL_ARTIFACT_DIR:-}" ] && cp "$sandbox/ci_temp/review_run.log" "$EVAL_ARTIFACT_DIR/$(basename "$fdir").lastlog" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# evaluate_fixture <manifest> <result-file> <log-file>
#
# One fixture, start to verdict. Runs in a BACKGROUND SUBSHELL, so it must not
# touch the parent's arrays or counters — it communicates by writing exactly one
# `kind|id|verdict|detail` line to <result-file>, and its console output to
# <log-file>. The driver replays the logs and tallies the counters afterwards,
# in manifest order, so a parallel run produces byte-identical output ordering
# to a serial one and the report stays deterministic.
#
# Isolation was checked before this was parallelised, not assumed: run_fixture
# builds its own `mktemp -d` sandbox and `cd`s into it inside a subshell, so the
# `ci_temp/` that review-in-chunks.sh writes is per-fixture; artifact copies are
# keyed on the unique fixture id; and nothing else is shared but the read-only
# corpus. The one genuine cross-fixture resource is the model endpoint — see
# EVAL_PARALLEL.
# ---------------------------------------------------------------------------
evaluate_fixture() {
  local manifest="$1" result_file="$2" log_file="$3"
  local id kind label min_sev
  id="$(jq -r '.id' "$manifest")"
  kind="$(jq -r '.kind' "$manifest")"
  label="$(jq -r '.label // .id' "$manifest")"
  min_sev="$(jq -r '.min_severity // "HIGH"' "$manifest" | tr '[:lower:]' '[:upper:]')"

  {
  echo "▶ [$kind] $id ($label)"

  # Run EVAL_SAMPLES times; collect the blocking-severity set from each sample.
  flagged_any=false           # precision: did ANY sample flag Crit/High/Med?
  caught_count=0              # recall: how many samples caught >= min_sev?
  sample_infra_fail=false
  for ((s=1; s<=EVAL_SAMPLES; s++)); do
    out="$(run_fixture "$manifest")" || { sample_infra_fail=true; break; }
    if [ "$out" = "__INFRA_FAIL__" ]; then sample_infra_fail=true; break; fi
    sevs="${out#*|}"          # e.g. "HIGH,MEDIUM" or ""

    # precision: any of CRITICAL/HIGH/MEDIUM present is a re-raised false positive.
    # NOTE: this precision bar is intentionally STRICTER than the production gate's
    # blocking threshold — the gate blocks a PR only on [VERIFIED] Critical/High
    # (LADR-012/015), but a re-raised DR at MEDIUM is still review noise on a
    # confirmed false positive, so the eval fails on it too. Low/none is allowed.
    if printf '%s' "$sevs" | grep -qE '(CRITICAL|HIGH|MEDIUM)'; then
      flagged_any=true
    fi
    # recall: caught if a flag at >= min_sev is present
    case "$min_sev" in
      CRITICAL) printf '%s' "$sevs" | grep -q 'CRITICAL' && caught_count=$((caught_count+1)) ;;
      HIGH)     printf '%s' "$sevs" | grep -qE '(CRITICAL|HIGH)' && caught_count=$((caught_count+1)) ;;
      MEDIUM)   printf '%s' "$sevs" | grep -qE '(CRITICAL|HIGH|MEDIUM)' && caught_count=$((caught_count+1)) ;;
      *)        printf '%s' "$sevs" | grep -qE '(CRITICAL|HIGH)' && caught_count=$((caught_count+1)) ;;
    esac
    [ "$EVAL_SAMPLES" -gt 1 ] && echo "    sample $s/$EVAL_SAMPLES: [${sevs:-clean}]"
  done

  if [ "$sample_infra_fail" = true ]; then
    printf '%s\n' "$kind|$id|INFRA|model/run failure — see logs in $WORK_ROOT" > "$result_file"
    echo "    ⚠️  INFRA FAILURE (no usable review)"
    return 0
  fi

  # Triage archive: keep the (last sample's) review so a precision FAIL can be
  # inspected after the sandbox is wiped. Skipped under selftest (no real review).
  if [ -n "$EVAL_ARTIFACT_DIR" ] && [ "$SELFTEST" != "1" ]; then
    review_path="${out%|*}"
    if [ -n "$review_path" ] && [ -f "$review_path" ]; then
      cp "$review_path" "$EVAL_ARTIFACT_DIR/$id.review.md" 2>/dev/null || true
    fi
  fi

  if [ "$kind" = "must-not-flag" ]; then
    if [ "$flagged_any" = true ]; then
      printf '%s\n' "$kind|$id|FAIL|re-raised a known false positive (DR regression)" > "$result_file"
      echo "    ❌ FAIL — flagged at Critical/High/Medium on a must-not-flag fixture ($label)"
      # Print the offending finding labels inline. Without this the message names
      # only the DR, which reads as "the reviewer re-raised DR-XXX" even when it
      # flagged something else entirely — diagnosing a failure meant downloading
      # the run artifact and reading the review by hand. Three of the three
      # precision failures triaged on run 30766652401 turned out to be findings
      # unrelated to their DR (an unrelated perf note, a real script-injection
      # vector left in the fixture), which is a fixture defect rather than a
      # precision regression, and the message actively pointed away from that.
      if [ -n "${review_path:-}" ] && [ -f "$review_path" ]; then
        grep -oE '^- (🔴|🟠|🟡) \[VERIFIED\][^—]*' "$review_path" 2>/dev/null \
          | cut -c1-160 | sed 's/^/       ↳ /' | head -5 || true
      fi
    else
      printf '%s\n' "$kind|$id|PASS|did not re-raise" > "$result_file"
      echo "    ✅ PASS"
    fi
  else
    local need
    need=$(majority "$EVAL_SAMPLES")
    if [ "$caught_count" -ge "$need" ]; then
      printf '%s\n' "$kind|$id|PASS|caught seeded defect (>= $min_sev) in $caught_count/$EVAL_SAMPLES" > "$result_file"
      echo "    ✅ PASS — caught >= $min_sev ($caught_count/$EVAL_SAMPLES)"
    else
      printf '%s\n' "$kind|$id|FAIL|missed seeded defect ($caught_count/$EVAL_SAMPLES caught, need $need)" > "$result_file"
      echo "    ❌ FAIL — missed seeded defect ($caught_count/$EVAL_SAMPLES)"
    fi
  fi
  } > "$log_file" 2>&1
}

# ---------------------------------------------------------------------------
# Driver: run fixtures with a bounded worker pool, then tally in manifest order.
#
# EVAL_PARALLEL is the number of fixtures in flight, and the ONLY thing it
# trades is wall-clock against pressure on the model endpoint. Each in-flight
# fixture is one live chunk-review call, so a high value can earn provider rate
# limiting — which surfaces as INFRA failures and fails the run. That is a
# flaky gate, which is the exact failure this harness was just rescued from, so
# the default is deliberately conservative. Raise it only with evidence from a
# real run. (review-in-chunks.sh caps its own chunk fan-out at 10 for the same
# reason; eval fixtures are 1-2 files, so each is normally a single chunk.)
# ---------------------------------------------------------------------------
_eval_parallel_explicit="${EVAL_PARALLEL+set}"
EVAL_PARALLEL="${EVAL_PARALLEL:-4}"
case "$EVAL_PARALLEL" in
  ''|*[!0-9]*) EVAL_PARALLEL=4 ;;
esac
[ "$EVAL_PARALLEL" -ge 1 ] || EVAL_PARALLEL=4
# The self-test scores canned reviews with no network, so parallelism buys it
# nothing by default. An EXPLICIT EVAL_PARALLEL still applies, which is how
# test-evals.sh exercises the worker pool itself — otherwise the pool would be
# reachable only by a paid run.
if [ "$SELFTEST" = "1" ] && [ -z "$_eval_parallel_explicit" ]; then
  EVAL_PARALLEL=1
fi
# The pool throttles with `wait -n`, which is bash 4.3+. macOS still ships bash
# 3.2 as /bin/bash, and local-evals.sh is the documented macOS path — there,
# `wait -n` fails immediately and the throttle would degrade to launching every
# fixture at once. Fall back to serial rather than melting someone's rate limit.
if [ "$EVAL_PARALLEL" -gt 1 ] && \
   { [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || \
     { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; }; then
  echo "ℹ️  bash ${BASH_VERSION:-?} lacks 'wait -n' (needs 4.3+) — running fixtures serially."
  EVAL_PARALLEL=1
fi

[ "$EVAL_PARALLEL" -gt 1 ] && echo "Running up to ${EVAL_PARALLEL} fixtures concurrently (EVAL_PARALLEL)."
echo ""

declare -a PENDING=()          # manifests actually launched, in corpus order
for manifest in "${manifests[@]}"; do
  fid="$(jq -r '.id' "$manifest")"
  if [ -n "$EVAL_FILTER" ] && [[ "$fid" != *"$EVAL_FILTER"* ]]; then
    continue
  fi
  PENDING+=("$manifest")
done

RESULT_DIR="$WORK_ROOT/results"
mkdir -p "$RESULT_DIR"

slot=0
for manifest in "${PENDING[@]}"; do
  # Throttle: wait for a slot before launching. `wait -n` needs bash 4.3+; the
  # runner ships bash 5 and the preflight already requires a modern bash.
  while [ "$(jobs -rp | wc -l)" -ge "$EVAL_PARALLEL" ]; do
    wait -n 2>/dev/null || break
  done
  evaluate_fixture "$manifest" "$RESULT_DIR/$slot.result" "$RESULT_DIR/$slot.log" &
  slot=$((slot+1))
done
wait

# Tally in launch order — never in completion order — so the printed log and the
# RESULTS table are identical run to run regardless of which fixture finished
# first. A missing result file means the worker died outright (OOM, kill); that
# counts as an infra failure rather than being silently dropped.
slot=0
for manifest in "${PENDING[@]}"; do
  fid="$(jq -r '.id' "$manifest")"
  fkind="$(jq -r '.kind' "$manifest")"
  [ -f "$RESULT_DIR/$slot.log" ] && cat "$RESULT_DIR/$slot.log"
  line=""
  [ -f "$RESULT_DIR/$slot.result" ] && line="$(cat "$RESULT_DIR/$slot.result")"
  if [ -z "$line" ]; then
    line="$fkind|$fid|INFRA|worker produced no result — see logs in $WORK_ROOT"
    echo "    ⚠️  INFRA FAILURE (worker produced no result)"
  fi
  RESULTS+=("$line")

  verdict="$(printf '%s' "$line" | cut -d'|' -f3)"
  # An INFRA failure is counted ONLY as infra — never in the precision or recall
  # denominators. The serial version reached this via `continue`; getting it
  # wrong here would quietly inflate both denominators and understate the two
  # rates the gate is judged on.
  if [ "$verdict" = "INFRA" ]; then
    infra_fail=$((infra_fail+1))
  else
    case "$fkind" in
      must-not-flag)
        precision_total=$((precision_total+1))
        [ "$verdict" = "FAIL" ] && precision_fail=$((precision_fail+1))
        ;;
      *)
        recall_total=$((recall_total+1))
        [ "$verdict" = "PASS" ] && recall_caught=$((recall_caught+1))
        ;;
    esac
  fi
  slot=$((slot+1))
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
# A rate over a zero denominator is not 100%, it is "nothing was measured".
# Printing "Precision … 0/0 clean (100%)" under a total provider outage is a
# line someone will screenshot out of context, and it says the opposite of what
# happened. The run already fails on the infra count; the summary should agree.
precision_display="${precision_rate}%"
recall_display="${recall_rate}%"
[ "$precision_total" -eq 0 ] && precision_display="n/a — nothing scored"
[ "$recall_total" -eq 0 ] && recall_display="n/a — nothing scored"
echo " Precision (must-not-flag): $precision_pass/$precision_total clean (${precision_display})  [zero-tolerance]"
echo " Recall    (must-catch)   : $recall_caught/$recall_total caught (${recall_display})  [threshold ${EVAL_RECALL_THRESHOLD}%]"
[ "$infra_fail" -gt 0 ] && echo " Infra failures           : $infra_fail (counted as run failure)"
[ -n "$EVAL_ARTIFACT_DIR" ] && echo " Reviews archived to      : $EVAL_ARTIFACT_DIR (per-fixture <id>.review.md)"
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
