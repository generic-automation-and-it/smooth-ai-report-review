#!/bin/bash
# test-evals.sh — STRUCTURAL self-test for the eval harness.
#
# Validates the parsing / scoring / aggregation / gating / exit-code logic with a
# STUBBED model (EVAL_SELFTEST=1 scores canned reviews) — it makes NO real model
# calls and needs no credentials, so it is SAFE for the default bash-test path.
# The REAL paid eval is run-evals.sh / local-evals.sh, which this does not invoke.
set -euo pipefail

echo "=========================================="
echo " Eval harness structural self-test"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCORE="$SCRIPT_DIR/lib/score-review.sh"
RUNNER="$SCRIPT_DIR/run-evals.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-evals.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0; fail=0
ok()   { echo "✅ $1"; pass=$((pass+1)); }
bad()  { echo "❌ $1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Part 1 — score-review.sh grammar (the highest-risk logic).
# Each case: write a review snippet, assert the scored severity set.
# ---------------------------------------------------------------------------
echo "--- Part 1: scorer grammar ---"

score_of() { printf '%s\n' "$1" > "$TMP_DIR/r.md"; bash "$SCORE" "$TMP_DIR/r.md" | paste -sd, -; }
expect_score() {
  local label="$1" input="$2" want="$3" got
  got="$(score_of "$input")"
  if [ "$got" = "$want" ]; then ok "$label (got: [${got:-none}])"; else bad "$label — want [${want:-none}], got [${got:-none}]"; fi
}

expect_score "all None found -> clean" \
'### 📄 File: `x.cs`
- 🔴 [VERIFIED] Critical: None found
- 🟠 [VERIFIED] High Priority: None found
- 🟡 [VERIFIED] Medium Priority: None found
- 🔵 [VERIFIED] Low Priority: None found' \
''

expect_score "verified critical -> CRITICAL" \
'- 🔴 [VERIFIED] Critical: SQL injection via string concatenation
- 🟠 [VERIFIED] High Priority: None found' \
'CRITICAL'

expect_score "verified high -> HIGH" \
'- 🔴 [VERIFIED] Critical: None found
- 🟠 [VERIFIED] High Priority: NRE on materialized list element' \
'HIGH'

expect_score "verified medium -> MEDIUM" \
'- 🟡 [VERIFIED] Medium Priority: missing index on FK column' \
'MEDIUM'

expect_score "speculative high is NOT counted" \
'- 🟠 [SPECULATIVE] High Priority: maybe a problem in an unseen file
- 🔴 [VERIFIED] Critical: None found' \
''

expect_score "None-found variants (bold / period / quoted) -> clean" \
'- 🔴 [VERIFIED] Critical: **None found**
- 🟠 [VERIFIED] High Priority: None found.
- 🟡 [VERIFIED] Medium Priority: "none"' \
''

expect_score "word critical in a HIGH description does not become CRITICAL" \
'- 🔴 [VERIFIED] Critical: None found
- 🟠 [VERIFIED] High Priority: this is a critical-path method, validate input' \
'HIGH'

expect_score "colon in description still parses payload correctly" \
'- 🟠 [VERIFIED] High Priority: bug: missing await on async call' \
'HIGH'

expect_score "multiple severities reported together" \
'- 🔴 [VERIFIED] Critical: deadlock risk
- 🟠 [VERIFIED] High Priority: unvalidated input' \
'CRITICAL,HIGH'

echo ""

# ---------------------------------------------------------------------------
# Part 2 — corpus walk + aggregation + gating + exit codes (EVAL_SELFTEST=1).
# Build throwaway corpora with canned reviews and assert run-evals exit status.
# ---------------------------------------------------------------------------
echo "--- Part 2: aggregation + gating ---"

make_fixture() {  # <corpus> <kind> <id> <min_severity> <review-markdown>
  local corpus="$1" kind="$2" id="$3" minsev="$4" review="$5"
  local d="$corpus/$kind/$id"
  mkdir -p "$d"
  jq -n --arg id "$id" --arg kind "$kind" --arg label "$id" --arg ms "$minsev" \
    '{id:$id, kind:$kind, label:$label, min_severity:$ms, note:"selftest"}' > "$d/manifest.json"
  printf '%s\n' "$review" > "$d/selftest-review.md"
}

run_corpus() {  # <corpus> [extra VAR=val ...] -> returns run-evals exit status
  local corpus="$1"; shift
  # Use `env` so VAR=val args (incl. ones from "$@") are parsed as assignments —
  # a word produced by expansion is NOT treated as a shell assignment.
  env EVAL_SELFTEST=1 EVAL_CORPUS_DIR="$corpus" "$@" bash "$RUNNER" >"$corpus/out.log" 2>&1
}

CLEAN_MNF='- 🔴 [VERIFIED] Critical: None found
- 🟠 [VERIFIED] High Priority: None found
- 🟡 [VERIFIED] Medium Priority: None found'
CAUGHT_HIGH='- 🟠 [VERIFIED] High Priority: real seeded defect'
CAUGHT_CRIT='- 🔴 [VERIFIED] Critical: real seeded defect'
CAUGHT_MEDIUM='- 🟡 [VERIFIED] Medium Priority: real seeded defect'
REGRESSION='- 🟠 [VERIFIED] High Priority: re-raised a known false positive'

# Case A: everything passes -> exit 0
A="$TMP_DIR/corpusA"
make_fixture "$A" must-not-flag dr-clean HIGH "$CLEAN_MNF"
make_fixture "$A" must-catch    mc-caught HIGH "$CAUGHT_HIGH"
if run_corpus "$A"; then ok "all-pass corpus -> exit 0"; else bad "all-pass corpus should exit 0 (see $A/out.log)"; fi

# Case B: a must-not-flag fixture re-raises -> precision regression -> non-zero
B="$TMP_DIR/corpusB"
make_fixture "$B" must-not-flag dr-regress HIGH "$REGRESSION"
make_fixture "$B" must-catch    mc-caught  HIGH "$CAUGHT_HIGH"
if run_corpus "$B"; then bad "precision regression should exit non-zero (see $B/out.log)"; else ok "precision regression -> exit non-zero"; fi

# Case C: must-catch misses, recall below threshold -> non-zero
C="$TMP_DIR/corpusC"
make_fixture "$C" must-not-flag dr-clean HIGH "$CLEAN_MNF"
make_fixture "$C" must-catch    mc-missed HIGH "$CLEAN_MNF"   # reviewer found nothing
if run_corpus "$C"; then bad "recall miss should exit non-zero (see $C/out.log)"; else ok "recall below threshold -> exit non-zero"; fi

# Case D: recall miss but threshold lowered to 0 -> passes (threshold is configurable)
D="$TMP_DIR/corpusD"
make_fixture "$D" must-not-flag dr-clean HIGH "$CLEAN_MNF"
make_fixture "$D" must-catch    mc-missed HIGH "$CLEAN_MNF"
if run_corpus "$D" EVAL_RECALL_THRESHOLD=0; then ok "configurable threshold (0%) -> exit 0"; else bad "threshold=0 should pass (see $D/out.log)"; fi

# Case E: min_severity CRITICAL not met by a HIGH flag -> recall miss
E="$TMP_DIR/corpusE"
make_fixture "$E" must-catch mc-needs-crit CRITICAL "$CAUGHT_HIGH"   # only HIGH, needs CRITICAL
if run_corpus "$E"; then bad "min_severity CRITICAL unmet should exit non-zero (see $E/out.log)"; else ok "min_severity CRITICAL unmet -> exit non-zero"; fi

# Case F: min_severity CRITICAL met by a CRITICAL flag -> pass
F="$TMP_DIR/corpusF"
make_fixture "$F" must-catch mc-crit CRITICAL "$CAUGHT_CRIT"
if run_corpus "$F"; then ok "min_severity CRITICAL met -> exit 0"; else bad "CRITICAL met should pass (see $F/out.log)"; fi

# Case G: min_severity MEDIUM met by a MEDIUM flag -> pass
G="$TMP_DIR/corpusG"
make_fixture "$G" must-catch mc-medium MEDIUM "$CAUGHT_MEDIUM"
if run_corpus "$G"; then ok "min_severity MEDIUM met -> exit 0"; else bad "MEDIUM met should pass (see $G/out.log)"; fi

# Case H: min_severity HIGH is not met by only a MEDIUM flag -> recall miss
H="$TMP_DIR/corpusH"
make_fixture "$H" must-catch mc-high HIGH "$CAUGHT_MEDIUM"
if run_corpus "$H"; then bad "min_severity HIGH should not be met by MEDIUM (see $H/out.log)"; else ok "min_severity HIGH not met by MEDIUM -> exit non-zero"; fi

echo ""
echo "=========================================="
echo " Self-test: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ] || exit 1
