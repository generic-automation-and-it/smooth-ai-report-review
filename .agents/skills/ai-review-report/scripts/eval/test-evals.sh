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

expect_score "confidence parenthetical does not turn None found into a flag" \
'- 🔴 [VERIFIED] Critical (confidence: 100): None found
- 🟠 [VERIFIED] High Priority (confidence: 100): None found
- 🟡 [VERIFIED] Medium Priority (confidence: 100): None found' \
''

expect_score "confidence parenthetical still scores a real finding" \
'- 🟡 [VERIFIED] Medium Priority (confidence: 75): `x.yml:43` a real problem' \
'MEDIUM'

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

make_fixture() {  # <corpus> <kind> <id> <min_severity> <review-markdown> [forbidden_claim]
  local corpus="$1" kind="$2" id="$3" minsev="$4" review="$5" claim="${6:-}"
  local d="$corpus/$kind/$id"
  mkdir -p "$d"
  jq -n --arg id "$id" --arg kind "$kind" --arg label "$id" --arg ms "$minsev" --arg fc "$claim" \
    '{id:$id, kind:$kind, label:$label, min_severity:$ms, note:"selftest"}
     + (if $fc == "" then {} else {forbidden_claim:$fc} end)' > "$d/manifest.json"
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

# Case I: the worker pool. The fixtures are evaluated concurrently, but the
# report must be byte-identical to a serial run — same verdicts, same ORDER, same
# exit status. Order is the part worth pinning: the driver tallies in launch
# order rather than completion order precisely so a parallel run cannot reshuffle
# the RESULTS table, and a regression there would look like flakiness rather
# than like a bug.
I="$TMP_DIR/corpusI"
make_fixture "$I" must-not-flag dr-one   HIGH "$CLEAN_MNF"
make_fixture "$I" must-not-flag dr-two   HIGH "$CLEAN_MNF"
make_fixture "$I" must-not-flag dr-three HIGH "$CLEAN_MNF"
make_fixture "$I" must-catch    mc-one   HIGH "$CAUGHT_HIGH"
make_fixture "$I" must-catch    mc-two   HIGH "$CAUGHT_HIGH"

table_of() {  # strip the RESULTS table out of a run log
  awk '/^KIND /{f=1} f' "$1" | grep -E '^(must-not-flag|must-catch) ' || true
}

if run_corpus "$I" EVAL_PARALLEL=1; then
  cp "$I/out.log" "$I/serial.log"
  if run_corpus "$I" EVAL_PARALLEL=4; then
    if [ "$(table_of "$I/serial.log")" = "$(table_of "$I/out.log")" ]; then
      ok "parallel run reproduces the serial RESULTS table exactly (order + verdicts)"
    else
      bad "parallel run reordered or changed the RESULTS table"
      diff <(table_of "$I/serial.log") <(table_of "$I/out.log") | sed 's/^/     /'
    fi
  else
    bad "parallel run exited non-zero on an all-pass corpus (see $I/out.log)"
  fi
else
  bad "serial baseline exited non-zero on an all-pass corpus (see $I/out.log)"
fi

# Case J: a regression must still fail the gate when found by a parallel worker —
# the verdict has to survive the subshell boundary via the result file.
J="$TMP_DIR/corpusJ"
make_fixture "$J" must-not-flag dr-ok   HIGH "$CLEAN_MNF"
make_fixture "$J" must-not-flag dr-bad  HIGH "$REGRESSION"
make_fixture "$J" must-catch    mc-ok   HIGH "$CAUGHT_HIGH"
if run_corpus "$J" EVAL_PARALLEL=4; then
  bad "parallel precision regression should fail the gate (see $J/out.log)"
else
  ok "parallel precision regression still fails the gate"
fi

# Case K: a failed chunk must be an INFRA failure, never a clean review.
# review-in-chunks.sh writes a NON-EMPTY stub when the model chain is exhausted
# and drops a LADR-031 flag file beside it. Scored as an ordinary review that
# stub has no [VERIFIED] findings, so a must-not-flag fixture PASSES — which is
# how run 30791708130 reported precision 14/14 (100%) during a total provider
# outage, having reviewed nothing at all. A precision-only corpus would have gone
# green. Two properties are pinned here: the detection is by FLAG FILE (never by
# grepping the stub text, per LADR-031, because a quoted marker in a real review
# false-matched once), and it is checked BEFORE the emptiness test that the stub
# slips past.
echo "Case K: failed chunk is INFRA, not a clean review"
if grep -q 'compgen -G "\$sandbox/ci_temp/reviews/chunk_\*\.failed"' "$RUNNER"; then
  ok "run_fixture detects the LADR-031 flag file"
else
  bad "run_fixture no longer detects chunk_*.failed — a model outage will score as clean"
fi

flag_line="$(grep -n 'chunk_\*\.failed' "$RUNNER" | head -n1 | cut -d: -f1)"
empty_line="$(grep -n 'if \[ ! -s "\$review_md" \]' "$RUNNER" | head -n1 | cut -d: -f1)"
if [ -n "$flag_line" ] && [ -n "$empty_line" ] && [ "$flag_line" -lt "$empty_line" ]; then
  ok "flag-file check precedes the emptiness check (the stub is non-empty)"
else
  bad "flag-file check must run before the emptiness check (flag=$flag_line, empty=$empty_line)"
fi

if grep -qE 'grep .*(Review Failed for Chunk|fallbacks exhausted)' "$RUNNER"; then
  bad "chunk failure is detected by grepping stub text — LADR-031 requires the flag file"
else
  ok "no text-grep detection of chunk failure (LADR-031 channel respected)"
fi

# Case L: forbidden_claim rescoping. A must-not-flag fixture fails only when a
# flagged finding matches the DR claim; a true finding about something else is
# counted and reported, not blocking. Before this, ANY Critical/High/Medium
# failed the fixture, which measured "did the reviewer find anything at all in
# realistic code" — across five runs every failure was a correct finding and not
# one was a DR re-raise.
L="$TMP_DIR/corpusL"
make_fixture "$L" must-not-flag dr-claim-hit  HIGH \
  '- 🟠 [VERIFIED] High Priority: suggest a public constructor instead of the static factory' \
  'public constructor|factory interface'
if run_corpus "$L"; then bad "a finding matching forbidden_claim must fail (see $L/out.log)"; else ok "finding matching forbidden_claim fails the fixture"; fi

M="$TMP_DIR/corpusM"
make_fixture "$M" must-not-flag dr-unrelated  HIGH \
  '- 🟠 [VERIFIED] High Priority: the retry path leaves the two stores inconsistent' \
  'public constructor|factory interface'
make_fixture "$M" must-catch    mc-ok         HIGH "$CAUGHT_HIGH"
if run_corpus "$M"; then ok "unrelated true finding does not fail the fixture"; else bad "unrelated finding must not block (see $M/out.log)"; fi
if grep -q "Unrelated findings" "$M/out.log"; then ok "unrelated findings are reported in the summary"; else bad "unrelated findings not reported"; fi

N="$TMP_DIR/corpusN"
make_fixture "$N" must-not-flag dr-no-pattern HIGH \
  '- 🟠 [VERIFIED] High Priority: some unrelated true finding'
if run_corpus "$N"; then bad "a manifest without forbidden_claim must stay strict (see $N/out.log)"; else ok "no forbidden_claim keeps the strict behaviour"; fi

# --- Case O: multi-sample precision uses a MAJORITY, judged per sample -------
# Two properties, and the second is the one that matters most.
#
# 1. A minority re-raise passes. One sample from a non-deterministic model
#    against a zero-tolerance gate is measurement noise: on run 30891074256
#    DR-002 re-raised and MC-003 was missed, and BOTH flipped on a rerun of the
#    same commit with the same model.
#
# 2. A MAJORITY re-raise fails even when the LAST sample is clean. This is the
#    discriminating case. Precision used to be judged against `${out%|*}` —
#    the last sample only — so re-raising in samples 1 and 2 and coming back
#    clean in sample 3 reported PASS and threw away a real regression. Both the
#    old code and the majority rule return PASS for a 1-of-3 hit, so a
#    minority-only test would NOT have caught that bug; it takes a 2-of-3 hit
#    with a clean tail to tell them apart.
#
# Per-sample canned reviews come from the `selftest-review.<N>.md` seam.
sample_review() {  # <corpus> <kind> <id> <sample-index> <review-markdown>
  printf '%s\n' "$5" > "$1/$2/$3/selftest-review.$4.md"
}

O="$TMP_DIR/corpusO"
make_fixture "$O" must-not-flag dr-minority HIGH "$CLEAN_MNF" 'known false positive'
sample_review "$O" must-not-flag dr-minority 1 "$REGRESSION"
sample_review "$O" must-not-flag dr-minority 2 "$CLEAN_MNF"
sample_review "$O" must-not-flag dr-minority 3 "$CLEAN_MNF"
if run_corpus "$O" EVAL_SAMPLES=3; then
  ok "a minority DR re-raise (1/3) passes the gate"
else
  bad "1-of-3 re-raise must not fail under the majority rule (see $O/out.log)"
fi
if grep -q "PASS (flaky)" "$O/out.log"; then
  ok "a minority re-raise is reported as flaky, not silently passed"
else
  bad "minority re-raise must be surfaced in the log (see $O/out.log)"
fi

P="$TMP_DIR/corpusP"
make_fixture "$P" must-not-flag dr-majority HIGH "$CLEAN_MNF" 'known false positive'
sample_review "$P" must-not-flag dr-majority 1 "$REGRESSION"
sample_review "$P" must-not-flag dr-majority 2 "$REGRESSION"
sample_review "$P" must-not-flag dr-majority 3 "$CLEAN_MNF"
if run_corpus "$P" EVAL_SAMPLES=3; then
  bad "2-of-3 re-raise with a clean LAST sample must fail — the pre-fix code passed this (see $P/out.log)"
else
  ok "a majority DR re-raise fails even when the last sample is clean"
fi
if grep -q "2/3 sample" "$P/out.log"; then
  ok "the failure names how many samples re-raised"
else
  bad "failure detail must report the hit count (see $P/out.log)"
fi

# Case Q: every shipped must-not-flag manifest carries a forbidden_claim, each
# one compiles as an ERE, and DR-014's discriminates. DR-014 was the last
# fixture without a claim pattern, which put it in strict mode where ANY
# Critical/High/Medium failed it — including the connection-string-validation
# finding its own docstring blesses in prose the scorer cannot read. It failed
# 2 of 3 samples on that true finding (run 35322499612 attempts 2 and 3, run
# 35329091011). The risk of adding a claim is the opposite failure: a pattern
# loose enough to match everything makes the fixture unfailable, which is worse
# than the red it replaced. So the ERE is pinned from BOTH sides here — it must
# fire on objections to LADR-10's chosen approach, and must not fire on the
# adjacent true findings that are legitimately out of scope.
echo "Case Q: shipped forbidden_claim patterns discriminate"
CORPUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/corpus" && pwd)"

_missing_claim=""
for _m in "$CORPUS_DIR"/must-not-flag/*/manifest.json; do
  if [ "$(jq -r '.forbidden_claim // ""' "$_m")" = "" ]; then
    _missing_claim="$_missing_claim $(basename "$(dirname "$_m")")"
  fi
done
if [ -z "$_missing_claim" ]; then
  ok "every must-not-flag manifest has a forbidden_claim"
else
  bad "must-not-flag manifest(s) with no forbidden_claim:$_missing_claim"
fi

_bad_ere=""
for _m in "$CORPUS_DIR"/must-not-flag/*/manifest.json; do
  _fc="$(jq -r '.forbidden_claim // ""' "$_m")"
  [ -n "$_fc" ] || continue
  _rc=0
  printf 'probe\n' | grep -qiE "$_fc" >/dev/null 2>&1 || _rc=$?
  # rc 0 = matched, 1 = no match (both mean "compiles"); >1 = bad pattern.
  [ "$_rc" -gt 1 ] && _bad_ere="$_bad_ere $(basename "$(dirname "$_m")")" || true
done
if [ -z "$_bad_ere" ]; then
  ok "every forbidden_claim compiles as an ERE"
else
  bad "forbidden_claim(s) that do not compile:$_bad_ere"
fi

DR14="$(jq -r '.forbidden_claim' "$CORPUS_DIR/must-not-flag/DR-014-ladr-beats-prbody/manifest.json")"

# MUST fire: objections to LADR-10's chosen approach (no discriminator column,
# per-tenant database addressed by connection string).
_q_pos_miss=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  printf '%s\n' "$_line" | grep -qiE "$DR14" || { _q_pos_miss=$((_q_pos_miss+1)); echo "   ↳ MISSED: $_line"; } || true
done <<'POS'
- 🟠 [VERIFIED] High Priority: Tenant rows are not separated by a discriminator column, so a missing filter leaks data.
- 🟠 [VERIFIED] High Priority: No EF Core global query filter is configured for the tenant, risking cross-tenant reads.
- 🔴 [VERIFIED] Critical: HasQueryFilter is never called, so queries can return other tenants' rows.
- 🟠 [VERIFIED] High Priority: The design should use a shared database with a tenant column instead of one database per tenant.
- 🟡 [VERIFIED] Medium Priority: Database-per-tenant does not scale beyond a few hundred tenants; prefer a shared schema.
- 🟠 [VERIFIED] High Priority: db-per-tenant is an anti-pattern here and should be avoided.
- 🟠 [VERIFIED] High Priority: Tenant isolation is not enforced at the query layer; it relies solely on the connection string.
POS
if [ "$_q_pos_miss" -eq 0 ]; then
  ok "DR-014 forbidden_claim fires on chosen-approach objections"
else
  bad "DR-014 forbidden_claim missed $_q_pos_miss chosen-approach objection(s) — pattern too tight"
fi

# MUST NOT fire: the true adjacent findings the fixture docstring puts out of
# scope. The first two are the verbatim shapes observed in production runs.
_q_neg_hit=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  if printf '%s\n' "$_line" | grep -qiE "$DR14"; then
    _q_neg_hit=$((_q_neg_hit+1)); echo "   ↳ FALSE MATCH: $_line"
  fi
done <<'NEG'
- 🟡 [VERIFIED] Medium Priority: A tenant whose registry entry is empty or whitespace receives that value as a valid connection string, causing a delayed database failure instead of a clear configuration error.
- 🟡 [VERIFIED] Medium Priority: A tenant configured with an empty or whitespace-only connection string is treated as successfully resolved, causing database operations to fail later with an unrelated provider error.
- 🟡 [VERIFIED] Medium Priority: IOptionsSnapshot is resolved per call; a singleton consumer would capture a stale snapshot.
- 🟠 [VERIFIED] High Priority: UnknownTenantException does not include the tenant id in a structured field, hampering diagnostics.
- 🟡 [VERIFIED] Medium Priority: ConnectionStrings dictionary lookup is case-sensitive, so tenant ids differing in case silently fail.
NEG
if [ "$_q_neg_hit" -eq 0 ]; then
  ok "DR-014 forbidden_claim ignores the adjacent out-of-scope findings"
else
  bad "DR-014 forbidden_claim false-matched $_q_neg_hit out-of-scope finding(s) — pattern too loose"
fi

# DR-002's pattern was `(redundant|duplicate|…).{0,60}(storage|store|write|persist)`,
# and a 60-character window let "retrying may then DUPLICATE or conflict with
# the first WRITE" — an atomicity finding, not a redundancy claim — fail the
# run (35566556046) while the SAME atomicity finding worded differently passed
# the run before it. The pattern now binds the adjective to its noun within two
# words, in either order, so the forbidden claim is "the dual write is
# redundant", not any sentence that happens to contain both words. Round two
# (review 5263727118, finding 1): "duplicate write(s)" is the RETRY sense
# almost every time a model writes it, so "duplicate" pairs only with the
# storage nouns, while the named-store forms — "the object-store write is
# redundant with the database write", "the secondary write is unnecessary" —
# are matched explicitly. Both lists below carry the concise phrasings that
# broke the previous pattern in each direction. Round three (review
# 5264311874, finding 2) adds the active-verb and adverb forms — "writing to
# both stores DUPLICATES the data", "NEEDLESSLY writes twice" — keyed on an
# architectural subject (both/dual/object-store/archive …), because a bare
# "duplicates the entry" is what a retry finding says too. The pattern is kept
# under the complexity ceiling of non-GNU greps on purpose: a longer draft
# compiled on GNU grep and was rejected by another implementation outright,
# which would read as "nothing forbidden" and pass every sample.
DR02="$(jq -r '.forbidden_claim' "$CORPUS_DIR/must-not-flag/DR-002-hybrid-storage/manifest.json")"
_q2_pos_miss=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  printf '%s\n' "$_line" | grep -qiE "$DR02" || { _q2_pos_miss=$((_q2_pos_miss+1)); echo "   ↳ MISSED: $_line"; } || true
done <<'POS'
- 🟠 [VERIFIED] High Priority: Writing the payload to both stores is redundant storage; keep the database write only.
- 🟡 [VERIFIED] Medium Priority: The second write to the object store is a duplicate write of the same payload.
- 🟡 [VERIFIED] Medium Priority: Storing the payload twice is unnecessary duplication of storage.
- 🔵 [VERIFIED] Low Priority: The two writes are redundant — the object store copy duplicates the database row.
- 🟡 [VERIFIED] Medium Priority: The dual write is superfluous persistence; one store suffices.
- 🟠 [VERIFIED] High Priority: Payload is duplicated in two stores with no reason given.
- 🟠 [VERIFIED] High Priority: The object-store write is redundant with the database write.
- 🟡 [VERIFIED] Medium Priority: The secondary write is unnecessary because the database already holds the payload.
- 🟡 [VERIFIED] Medium Priority: The object store copy is redundant.
- 🔵 [VERIFIED] Low Priority: Persisting the same payload to the object store is a needless second copy.
- 🟠 [VERIFIED] High Priority: Writing to both stores duplicates the data for no benefit.
- 🟡 [VERIFIED] Medium Priority: The handler needlessly writes the same payload twice.
- 🟡 [VERIFIED] Medium Priority: The payload is unnecessarily duplicated across the database and the object store.
- 🟡 [VERIFIED] Medium Priority: The object store write is duplicating the entry already persisted in the database.
- 🔵 [VERIFIED] Low Priority: Storing the payload in both places is wasteful; the archive duplicates the primary row.
POS
if [ "$_q2_pos_miss" -eq 0 ]; then
  ok "DR-002 forbidden_claim fires on redundant-storage objections"
else
  bad "DR-002 forbidden_claim missed $_q2_pos_miss redundant-storage objection(s) — pattern too tight"
fi
_q2_neg_hit=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  if printf '%s\n' "$_line" | grep -qiE "$DR02"; then
    _q2_neg_hit=$((_q2_neg_hit+1)); echo "   ↳ FALSE MATCH: $_line"
  fi
done <<'NEG'
- 🟠 [VERIFIED] High Priority: An object-store failure can leave an operational log stored only in the primary database, violating DR-002's requirement that both copies exist; retrying may then duplicate or conflict with the first write.
- 🟡 [VERIFIED] Medium Priority: A transient object-store failure can leave a log only in the primary database, violating the documented requirement that logs reach both stores.
- 🟠 [VERIFIED] High Priority: Once the primary write succeeds, an exception from PutAsync leaves the stores inconsistent and prevents fallback replay.
- 🟡 [VERIFIED] Medium Priority: The object-store key is entry.Id, so a retried command with a fresh id writes a second, orphaned copy rather than overwriting.
- 🟡 [VERIFIED] Medium Priority: Retries can cause duplicate writes.
- 🟡 [VERIFIED] Medium Priority: A retry could duplicate the write to the object store.
- 🟡 [VERIFIED] Medium Priority: Without idempotency, a retried PutAsync produces duplicate objects in the archive.
- 🟡 [VERIFIED] Medium Priority: A retried command duplicates the object-store upload because the key is regenerated.
- 🟡 [VERIFIED] Medium Priority: Retrying after a partial failure duplicates the entry unless PutAsync is idempotent.
- 🟡 [VERIFIED] Medium Priority: If the object store call is retried it will duplicate the payload upload; make it idempotent on entry.Id.
NEG
if [ "$_q2_neg_hit" -eq 0 ]; then
  ok "DR-002 forbidden_claim ignores atomicity and retry findings"
else
  bad "DR-002 forbidden_claim false-matched $_q2_neg_hit atomicity finding(s) — pattern too loose"
fi

# NOT tested here: that the archived triage artifact is the OFFENDING sample
# rather than whatever ran last. Artifact archiving is deliberately skipped
# under EVAL_SELFTEST (there is no real review to keep), so any assertion on it
# in this harness would pass unconditionally — which is worse than no test,
# because it implies coverage that does not exist. Verified by reading
# `review_path="${dr_review_path:-${out%|*}}"` in run-evals.sh instead.

echo ""
echo "=========================================="
echo " Self-test: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ] || exit 1
