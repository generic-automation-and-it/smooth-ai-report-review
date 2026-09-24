#!/bin/bash
set -e

# Test script for the LADR-093 decision-model scorer:
#   lib/score-findings-decisions.sh — preflight, per-finding + PR-level requests,
#                                     annotate / filter, the filter fence, and
#                                     the best-effort failure paths
#   lib/resolve-provider.sh         — the `decisions` scope
#   lib/render-findings-summary.sh  — the decision suffix and Coverage line
#   lib/merge-findings.py           — a chunk cannot supply `decisions` itself
#
# Offline: `curl` is a PATH shim that answers in the TypeSafe System One shape
# (verified live against https://opencode.ai/zen/v1/systemone on 2026-09-24:
# noul → {noul}, choice → {choice, probabilities, confidence}, score → {score,
# legend, probabilities, confidence}). Both providers share that shape, so the
# shim serves both; the provider tests assert what differs — URL, key, model.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCORER="$SCRIPT_DIR/lib/score-findings-decisions.sh"
RENDER_SH="$SCRIPT_DIR/lib/render-findings-summary.sh"
MERGE_PY="$SCRIPT_DIR/lib/merge-findings.py"
SCORE_SH="$SCRIPT_DIR/eval/lib/score-review.sh"
RUN_REVIEW="$SCRIPT_DIR/run-review.sh"
LOCAL_REVIEW="$SCRIPT_DIR/local-review.sh"
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"

TMP_DIR="$(mktemp -d)"
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$TMP_DIR"; if [ "$SUITE_COMPLETED" != "1" ]; then echo ""; echo "❌ SUITE ABORTED EARLY (exit $rc) — assertions after this point never ran"; fi' EXIT

echo "=========================================="
echo "Testing score-findings-decisions (LADR-093)"
echo "=========================================="
echo ""

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $name"
    pass=$((pass + 1))
  else
    echo "❌ $name"
    echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---"; printf '%s\n' "$actual"
    fail=$((fail + 1))
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "⏭️  jq unavailable — skipping decision-model tests"
  SUITE_COMPLETED=1
  exit 0
fi

# --- curl shim -------------------------------------------------------------------
# STUB_MODE: ok | http500 | timeout | badjson | malformed_findings | pr_fail
# Every call leaves url_<n>, argv_<n>, hdr_<n> and req_<n>.json in $STUB_DIR.
BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'SHIM'
#!/bin/bash
out=""; data=""; url=""; hdr_file=""
argv="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--max-time) shift 2 ;;
    -H) case "$2" in @*) hdr_file="${2#@}" ;; esac; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
# mkdir is atomic: the scorer runs requests concurrently, and a count-then-write
# slot would let two parallel calls claim the same number.
n=1
while ! mkdir "$STUB_DIR/slot_$n" 2>/dev/null; do n=$((n + 1)); done
printf '%s' "$url" > "$STUB_DIR/url_$n"
printf '%s' "$argv" > "$STUB_DIR/argv_$n"
[ -n "$hdr_file" ] && cp "$hdr_file" "$STUB_DIR/hdr_$n"
cp "$data" "$STUB_DIR/req_$n.json"
kind="$(jq -r '.questions | if has("preflight") then "preflight" elif has("block_merge") then "pr" else "finding" end' "$data")"
case "$STUB_MODE" in
  http500)  printf '{"error":{"message":"upstream exploded"}}' > "$out"; printf '500'; exit 0 ;;
  timeout)  printf '000'; exit 28 ;;
  dns)      echo "curl: (6) Could not resolve host: openrouter.ai" >&2; printf '000'; exit 6 ;;
  cut)      printf '{"model":"jev-1.13","answ' > "$out"; printf '200'; exit 28 ;;
  badjson)  printf '<html>gateway</html>' > "$out"; printf '200'; exit 0 ;;
esac
case "$kind" in
  preflight)
    printf '{"model":"jev-1.13","answers":{"preflight":{"type":"noul","noul":0.97}},"usage":{"input_tokens":90,"output_tokens":5}}' > "$out" ;;
  finding)
    if [ "$STUB_MODE" = "malformed_findings" ]; then
      printf '{"model":"jev-1.13","answers":{"supported":{"type":"noul"}}}' > "$out"
    else
      jq -c '
        .state.finding as $f
        | { model: "jev-1.13",
            answers: {
              supported: { type: "noul", noul: (if ($f.title | test("weak")) then 0.12 else 0.91 end) },
              severity: { type: "choice",
                          choice: (if ($f.title | test("overrated")) then "medium"
                                   elif ($f.title | test("critical")) then "critical"
                                   elif ($f.title | test("high")) then "high"
                                   elif ($f.title | test("medium")) then "medium"
                                   else "low" end),
                          probabilities: { critical: 0.1, high: 0.2, medium: 0.6, low: 0.1 },
                          confidence: 0.74 },
              pre_existing: { type: "noul", noul: 0.08 },
              actionability: { type: "score", score: 1.6, confidence: 0.6,
                               legend: { "0": "Advisory", "1": "Judgement", "2": "Mechanical" },
                               probabilities: { "0": 0.1, "1": 0.2, "2": 0.7 } } },
            usage: { input_tokens: 400, output_tokens: 60 } }' "$data" > "$out"
    fi ;;
  pr)
    if [ "$STUB_MODE" = "pr_fail" ]; then
      printf '{"error":{"message":"overloaded"}}' > "$out"; printf '529'; exit 0
    fi
    # pr_503_once: a gateway 503 on the first PR-level call, then an answer.
    if [ "$STUB_MODE" = "pr_503_once" ] && mkdir "$STUB_DIR/pr_503_seen" 2>/dev/null; then
      printf '{"error":{"message":"Service Unavailable"}}' > "$out"; printf '503'; exit 0
    fi
    printf '{"model":"jev-1.13","answers":{"block_merge":{"type":"noul","noul":0.83},"dominant_risk":{"type":"choice","choice":"correctness","probabilities":{"correctness":0.7,"security":0.1,"performance":0.1,"maintainability":0.05,"tests":0.05},"confidence":0.66},"overall_risk":{"type":"score","score":2.4,"legend":{"0":"Negligible","1":"Low","2":"Moderate","3":"High","4":"Severe"},"probabilities":{"0":0,"1":0.1,"2":0.4,"3":0.4,"4":0.1},"confidence":0.5}},"usage":{"input_tokens":700,"output_tokens":40}}' > "$out" ;;
esac
printf '200'
SHIM
chmod +x "$BIN/curl"

# --- fixtures --------------------------------------------------------------------
# A merged document in merge-findings.py's output shape: four findings numbered
# in severity order, two chunks, full coverage.
finding() { # finding <n> <title> <severity> <file> <line>
  cat <<J
{"#": $1, "title": "$2", "severity": "$3", "file": "$4", "line": $5,
 "why_it_matters": "Impact of $2.", "confidence": 100, "verified": true,
 "first_evidence": "$4:$5 -- code", "pre_existing": false, "requires_verification": false,
 "autofix_class": "gated_auto", "owner": "downstream-resolver", "suggested_fix": "Fix $2.", "chunks": [0]}
J
}
write_merged() { # write_merged <path> [merged_chunks-json]
  cat > "$1" <<J
{
  "status": "complete",
  "merged_chunks": ${2:-[0, 1]},
  "findings": [
    $(finding 1 "weak critical claim" critical src/a.sh 10),
    $(finding 2 "weak high claim" high src/a.sh 20),
    $(finding 3 "overrated high claim" high src/b.sh 5),
    $(finding 4 "solid medium claim" medium src/b.sh 7)
  ],
  "pre_existing_findings": [], "suppressed_findings": [],
  "residual_risks": ["Rollback path untested."], "testing_gaps": ["No test for the empty list."],
  "suppressed_by_confidence": {}, "demoted_no_quote": 0, "merged_duplicates": 0,
  "malformed_returns": 0, "malformed_findings": 0, "malformed_reasons": {}, "malformed_return_reasons": {}
}
J
}

DIFF="$TMP_DIR/pr_diff.txt"
cat > "$DIFF" <<'D'
diff --git a/src/a.sh b/src/a.sh
index 111..222 100644
--- a/src/a.sh
+++ b/src/a.sh
@@ -1,3 +1,4 @@ top
 one
+two
 three
@@ -15,4 +16,6 @@ middle
 keep
+added line twenty
+added line twenty-one
 keep
diff --git a/src/b.sh b/src/b.sh
--- a/src/b.sh
+++ b/src/b.sh
@@ -3,2 +3,3 @@
 b-context
+b-added
D

# run_scorer <case> <merged> <total_chunks> [env...] — runs the scorer with the
# shim on PATH and a fresh stub directory; output in $TMP_DIR/<case>.log.
run_scorer() {
  local name="$1" merged="$2" total="$3"
  shift 3
  export STUB_DIR="$TMP_DIR/stub_$name"
  rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
  mkdir -p "$TMP_DIR/reviews_$name"
  env PATH="$BIN:$PATH" STUB_DIR="$STUB_DIR" STUB_MODE="${STUB_MODE:-ok}" _DECISIONS_RETRY_DELAY=0 \
    OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 \
    OPENCODE_GO_OPENAI_API_KEY=go-secret-key OPENCODE_OPENROUTER_API_KEY=or-secret-key \
    "$@" \
    bash "$SCORER" "$merged" "$TMP_DIR/reviews_$name" "$total" "$DIFF" > "$TMP_DIR/$name.log" 2>&1
}
calls() { ls "$STUB_DIR"/url_* 2>/dev/null | wc -l | tr -d ' '; }

# --- Test 1: disabled → byte-identical, no request ---------------------------------
write_merged "$TMP_DIR/t1.json"; cp "$TMP_DIR/t1.json" "$TMP_DIR/t1.orig"
run_scorer t1 "$TMP_DIR/t1.json" 2 OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=0
check "Test 1a: disabled leaves the merged document byte-identical" "same" \
  "$(cmp -s "$TMP_DIR/t1.json" "$TMP_DIR/t1.orig" && echo same || echo changed)"
check "Test 1b: disabled makes no request" "0" "$(calls)"
check "Test 1c: disabled prints nothing" "" "$(cat "$TMP_DIR/t1.log")"
run_scorer t1u "$TMP_DIR/t1.json" 2 OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=
check "Test 1d: unset/empty toggle is off (default 0)" "same" \
  "$(cmp -s "$TMP_DIR/t1.json" "$TMP_DIR/t1.orig" && echo same || echo changed)"

# --- Test 2: annotate adds fields, rewrites nothing ---------------------------------
write_merged "$TMP_DIR/t2.json"; cp "$TMP_DIR/t2.json" "$TMP_DIR/t2.orig"
run_scorer t2 "$TMP_DIR/t2.json" 2
check "Test 2a: preflight + 4 findings + 1 PR-level request" "6" "$(calls)"
check "Test 2b: every finding carries decisions" "4" \
  "$(jq '[.findings[] | select(.decisions.supported != null)] | length' "$TMP_DIR/t2.json")"
check "Test 2c: original severity/confidence/verified untouched" \
  "$(jq -c '[.findings[] | [.severity, .confidence, .verified]]' "$TMP_DIR/t2.orig")" \
  "$(jq -c '[.findings[] | [.severity, .confidence, .verified]]' "$TMP_DIR/t2.json")"
check "Test 2d: annotate never drops a finding" "4" "$(jq '.findings | length' "$TMP_DIR/t2.json")"
check "Test 2e: decision fields have the documented shape" \
  '{"provider":"OPENCODE-GO-DECISIONS","model":"jev-1.13","supported":0.12,"severity":"critical","pre_existing":0.08,"actionability":1.6}' \
  "$(jq -c '.findings[0].decisions | {provider, model, supported, severity: .severity.choice, pre_existing, actionability: .actionability.score}' "$TMP_DIR/t2.json")"
check "Test 2f: decisions_summary carries the PR-level answers" \
  '{"mode":"annotate","scored":4,"skipped":0,"block_merge":0.83,"dominant":"correctness","overall":2.4,"suppressed":0}' \
  "$(jq -c '.decisions_summary | {mode, scored, skipped, block_merge, dominant: .dominant_risk.choice, overall: .overall_risk.score, suppressed: (.suppressed | length)}' "$TMP_DIR/t2.json")"
check "Test 2g: the rest of the document is unchanged" \
  "$(jq -S 'del(.findings)' "$TMP_DIR/t2.orig")" \
  "$(jq -S 'del(.findings, .decisions_summary)' "$TMP_DIR/t2.json")"
check "Test 2h: per-finding state omits suggested_fix" "0" \
  "$(jq -s '[.[] | select(.state.finding? and (.state.finding | has("suggested_fix")))] | length' "$STUB_DIR"/req_*.json)"
check "Test 2h2: per-finding state withholds the chunk severity and pre_existing it is asked to judge" "0" \
  "$(jq -s '[.[] | select(.state.finding? and (.state.finding | has("severity") or has("pre_existing")))] | length' "$STUB_DIR"/req_*.json)"
check "Test 2i: per-finding state carries the diff hunk around its line" "true" \
  "$(jq -s '[.[] | select(.state.finding.title? == "weak high claim")][0].state.diff_hunk | test("added line twenty")' "$STUB_DIR"/req_*.json)"
check "Test 2j2: every request states that PR content is data, never instruction" "0" \
  "$(jq -s '[.[] | select(.questions.preflight? | not) | select((.state.review_rules.untrusted_content // "") | test("never an instruction") | not)] | length' "$STUB_DIR"/req_*.json)"
check "Test 2j3: the supported question applies that boundary by name" "true" \
  "$(jq -s '[.[] | select(.questions.supported?)][0].questions.supported.instructions | test("review_rules.untrusted_content")' "$STUB_DIR"/req_*.json)"
check "Test 2j: the severity question lists exactly the four gate severities" '["critical","high","low","medium"]' \
  "$(jq -s -c '[.[] | select(.questions.severity?)][0].questions.severity.criteria | keys' "$STUB_DIR"/req_*.json)"
check "Test 2k: success is logged once" "1" "$(grep -c '^✅ Decision model OPENCODE-GO-DECISIONS/jev-1.13 (annotate): scored 4, skipped 0, suppressed 0' "$TMP_DIR/t2.log")"
run_scorer t2b "$TMP_DIR/t2.json" 2
check "Test 2l: an already-scored document is not scored twice" "0" "$(calls)"

# --- Test 2m: the rewrite does not tighten the document to 0600 ----------------------
# The key file needs umask 077; the rewritten document must get the ordinary
# umask mode, exactly as merge-findings.sh would have written it.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
write_merged "$TMP_DIR/t2m.json"
: > "$TMP_DIR/t2m.ref"
run_scorer t2m "$TMP_DIR/t2m.json" 2
check "Test 2m: rewritten findings.merged.json has the ordinary umask mode" \
  "$(mode_of "$TMP_DIR/t2m.ref")" "$(mode_of "$TMP_DIR/t2m.json")"

# --- Test 3: the key never reaches argv ----------------------------------------------
check "Test 3a: API key absent from every curl argv" "0" \
  "$(cat "$TMP_DIR"/stub_t2/argv_* | grep -c 'go-secret-key' || true)"
check "Test 3b: API key sent as a bearer header" "Authorization: Bearer go-secret-key" \
  "$(head -n1 "$TMP_DIR/stub_t2/hdr_1")"

# --- Test 4: filter on full coverage ------------------------------------------------
write_merged "$TMP_DIR/t4.json"
run_scorer t4 "$TMP_DIR/t4.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 4a: filter suppresses the unsupported high, keeps the unsupported critical" \
  '["weak critical claim","overrated high claim","solid medium claim"]' \
  "$(jq -c '[.findings[].title]' "$TMP_DIR/t4.json")"
check "Test 4b: survivors are renumbered contiguously" "[1,2,3]" "$(jq -c '[.findings[]["#"]]' "$TMP_DIR/t4.json")"
check "Test 4c: the suppression is recorded, never silent" \
  '[{"number_before_filter":2,"title":"weak high claim","severity":"high","supported":0.12}]' \
  "$(jq -c '[.decisions_summary.suppressed[] | {number_before_filter, title, severity, supported}]' "$TMP_DIR/t4.json")"
check "Test 4d: mode recorded as filter" "filter" "$(jq -r '.decisions_summary.mode' "$TMP_DIR/t4.json")"
write_merged "$TMP_DIR/t4b.json"
run_scorer t4b "$TMP_DIR/t4b.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY=0.95
check "Test 4e: critical is never suppressed, whatever the threshold" "critical" \
  "$(jq -r '[.findings[].severity] | join(",")' "$TMP_DIR/t4b.json")"

# --- Test 4f: no diff hunk is not evidence against a finding ------------------------
# The chunk model wrote the path as a basename, so the hunk lookup finds nothing.
# The judge must be told so explicitly, and filter must never suppress on it.
write_merged "$TMP_DIR/t4f.json"
jq '.findings[1].file = "a.sh"' "$TMP_DIR/t4f.json" > "$TMP_DIR/t4f.tmp" && mv "$TMP_DIR/t4f.tmp" "$TMP_DIR/t4f.json"
run_scorer t4f "$TMP_DIR/t4f.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 4f: a missing hunk is stated, not sent as an empty string" "true" \
  "$(jq -s '[.[] | select(.state.finding.file? == "a.sh")][0].state.diff_hunk | test("no diff hunk was found for this file")' "$STUB_DIR"/req_*.json)"
check "Test 4g: the finding records that its hunk was not found" "false" \
  "$(jq -r '[.findings[] | select(.file == "a.sh")][0].decisions.diff_hunk_found' "$TMP_DIR/t4f.json")"
check "Test 4h: filter never suppresses a finding whose hunk was not found" "0" \
  "$(jq '.decisions_summary.suppressed | length' "$TMP_DIR/t4f.json")"
check "Test 4i: a finding with a hunk records that too" "true" \
  "$(jq -r '[.findings[] | select(.file == "src/b.sh")][0].decisions.diff_hunk_found' "$TMP_DIR/t4f.json")"

# --- Test 5: filter degrades to annotate on partial coverage ------------------------
write_merged "$TMP_DIR/t5.json" "[0]"
run_scorer t5 "$TMP_DIR/t5.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 5a: missing sidecar → nothing suppressed" "4" "$(jq '.findings | length' "$TMP_DIR/t5.json")"
check "Test 5b: missing sidecar → mode annotate, requested filter" "annotate/filter" \
  "$(jq -r '.decisions_summary | "\(.mode)/\(.mode_requested)"' "$TMP_DIR/t5.json")"
check "Test 5c: the degrade names the missing chunk" "true" \
  "$(jq -r '.decisions_summary.mode_note | test("chunk\\(s\\) 1 contributed no structured findings")' "$TMP_DIR/t5.json")"
write_merged "$TMP_DIR/t5b.json"
mkdir -p "$TMP_DIR/reviews_t5b"; : > "$TMP_DIR/reviews_t5b/chunk_1.failed"
run_scorer t5b "$TMP_DIR/t5b.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 5d: a failed chunk → nothing suppressed" "4" "$(jq '.findings | length' "$TMP_DIR/t5b.json")"
check "Test 5e: a failed chunk is named in the log" "1" "$(grep -c 'degraded to annotate — partial coverage (1 chunk(s) failed)' "$TMP_DIR/t5b.log")"
write_merged "$TMP_DIR/t5c.json"
run_scorer t5c "$TMP_DIR/t5c.json" ""  OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 5f: unknown chunk total → nothing suppressed" "4" "$(jq '.findings | length' "$TMP_DIR/t5c.json")"
check "Test 5g: the scorer never writes a chunk failure flag" "0" \
  "$(find "$TMP_DIR"/reviews_t* -name 'chunk_*.failed' ! -path '*reviews_t5b*' | wc -l | tr -d ' ')"

# --- Test 6: provider failures leave the document untouched --------------------------
for mode in http500 timeout badjson cut; do
  write_merged "$TMP_DIR/t6_$mode.json"; cp "$TMP_DIR/t6_$mode.json" "$TMP_DIR/t6_$mode.orig"
  set +e
  STUB_MODE="$mode" run_scorer "t6_$mode" "$TMP_DIR/t6_$mode.json" 2
  rc=$?
  set -e
  check "Test 6 ($mode): exit code 0" "0" "$rc"
  check "Test 6 ($mode): merged document byte-identical" "same" \
    "$(cmp -s "$TMP_DIR/t6_$mode.json" "$TMP_DIR/t6_$mode.orig" && echo same || echo changed)"
  check "Test 6 ($mode): one ⚠️ provider-unavailable line" "1" \
    "$(grep -c '^⚠️  Decision model (LADR-093): decisions provider unavailable' "$TMP_DIR/t6_$mode.log")"
  check "Test 6 ($mode): the preflight stops the run — one request only" "1" "$(calls)"
done
check "Test 6d: the HTTP status and vendor message are reported" "1" \
  "$(grep -c 'HTTP 500: upstream exploded' "$TMP_DIR/t6_http500.log")"
check "Test 6e: a timeout is reported as one" "1" \
  "$(grep -c 'timeout or network error after 20s' "$TMP_DIR/t6_timeout.log")"
write_merged "$TMP_DIR/t6dns.json"; cp "$TMP_DIR/t6dns.json" "$TMP_DIR/t6dns.orig"
STUB_MODE=dns run_scorer t6dns "$TMP_DIR/t6dns.json" 2
check "Test 6e3: a transport failure carries curl own reason" "1" \
  "$(grep -c 'timeout or network error after 20s — curl: (6) Could not resolve host: openrouter.ai' "$TMP_DIR/t6dns.log")"
check "Test 6e4: ...and still leaves the document untouched" "same" \
  "$(cmp -s "$TMP_DIR/t6dns.json" "$TMP_DIR/t6dns.orig" && echo same || echo changed)"
check "Test 6e2: a timeout mid-body is a timeout, not an HTTP 200" "1" \
  "$(grep -c 'timeout or network error after 20s' "$TMP_DIR/t6_cut.log")"

write_merged "$TMP_DIR/t6m.json"
STUB_MODE=malformed_findings run_scorer t6m "$TMP_DIR/t6m.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 6f: malformed per-finding answers → findings unscored, none suppressed" "0/4/4/0" \
  "$(jq -r '"\(.decisions_summary.scored)/\(.decisions_summary.skipped)/\(.findings | length)/\([.findings[] | select(has("decisions"))] | length)"' "$TMP_DIR/t6m.json")"
check "Test 6g: malformed answers are warned about" "1" "$(grep -c 'left unscored — first failure: finding 1: malformed answer' "$TMP_DIR/t6m.log")"

write_merged "$TMP_DIR/t6p.json"
STUB_MODE=pr_fail run_scorer t6p "$TMP_DIR/t6p.json" 2
check "Test 6h: PR-level failure keeps the per-finding scores" "4/null/failed" \
  "$(jq -r '"\(.decisions_summary.scored)/\(.decisions_summary.block_merge)/\(.decisions_summary.pr_level_scope)"' "$TMP_DIR/t6p.json")"
check "Test 6i: a 529 is retried once before giving up" "7" "$(calls)"

write_merged "$TMP_DIR/t6r.json"
STUB_MODE=pr_503_once run_scorer t6r "$TMP_DIR/t6r.json" 2
check "Test 6j: a gateway 503 is retried once and then answered" "7/0.83" \
  "$(calls)/$(jq -r '.decisions_summary.block_merge' "$TMP_DIR/t6r.json")"

# --- Test 7: provider selectors ------------------------------------------------------
write_merged "$TMP_DIR/t7.json"
run_scorer t7 "$TMP_DIR/t7.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=openrouter-decisions
check "Test 7a: OPENROUTER-DECISIONS → the decisions endpoint" "https://openrouter.ai/api/alpha/decisions" "$(cat "$STUB_DIR/url_1")"
check "Test 7b: OPENROUTER-DECISIONS → the OpenRouter key" "Authorization: Bearer or-secret-key" "$(head -n1 "$STUB_DIR/hdr_1")"
check "Test 7c: OPENROUTER-DECISIONS → typesafe/jev-1.13 by default" "typesafe/jev-1.13" "$(jq -r .model "$STUB_DIR/req_1.json")"
write_merged "$TMP_DIR/t7b.json"
run_scorer t7b "$TMP_DIR/t7b.json" 2
check "Test 7d: default provider → the OpenCode Console systemone endpoint" "https://opencode.ai/zen/v1/systemone" "$(cat "$STUB_DIR/url_1")"
check "Test 7e: default provider → jev-1.13" "jev-1.13" "$(jq -r .model "$STUB_DIR/req_1.json")"
write_merged "$TMP_DIR/t7c.json"
run_scorer t7c "$TMP_DIR/t7c.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13-free
check "Test 7f: the model Variable overrides the default" "jev-1.13-free" "$(jq -r .model "$STUB_DIR/req_1.json")"
write_merged "$TMP_DIR/t7d.json"; cp "$TMP_DIR/t7d.json" "$TMP_DIR/t7d.orig"
run_scorer t7d "$TMP_DIR/t7d.json" 2 OPENCODE_GO_OPENAI_API_KEY=
check "Test 7g: missing key → untouched" "same" "$(cmp -s "$TMP_DIR/t7d.json" "$TMP_DIR/t7d.orig" && echo same || echo changed)"
check "Test 7h: missing key → warning names the Secret, no request" "1/0" \
  "$(grep -c 'OPENCODE_GO_OPENAI_API_KEY is empty/unset' "$TMP_DIR/t7d.log")/$(calls)"
run_scorer t7e "$TMP_DIR/t7d.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENAI
check "Test 7i: a chat provider is refused by the decisions scope" "1/0" \
  "$(grep -c 'is a chat provider' "$TMP_DIR/t7e.log")/$(calls)"
run_scorer t7f "$TMP_DIR/t7d.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=typesafe/jev-1.13
check "Test 7j: an OpenRouter model id on the OpenCode provider is refused" "1" "$(grep -c 'OpenRouter-style vendor/model id' "$TMP_DIR/t7f.log")"
check "Test 7k: the resolver never leaks the key into the log" "0" "$(cat "$TMP_DIR"/t7*.log | grep -c 'secret-key' || true)"

# --- Test 8: request budget ----------------------------------------------------------
BIG_DIFF="$TMP_DIR/big_diff.txt"
{
  echo 'diff --git a/src/a.sh b/src/a.sh'
  echo '@@ -1,1 +1,3000 @@'
  for _ in $(seq 1 3000); do echo "+$(printf 'x%.0s' $(seq 1 40))"; done
} > "$BIG_DIFF"
write_merged "$TMP_DIR/t8.json"
DIFF_SAVE="$DIFF"; DIFF="$BIG_DIFF"
run_scorer t8 "$TMP_DIR/t8.json" 2
DIFF="$DIFF_SAVE"
max_req="$(wc -c "$STUB_DIR"/req_*.json | grep -v total | awk '{print $1}' | sort -n | tail -1)"
check "Test 8a: no request exceeds the 24000-byte budget" "true" "$([ "$max_req" -le 24000 ] && echo true || echo "false ($max_req)")"
check "Test 8b: an oversized hunk is truncated, and says so" "true" \
  "$(jq -s '[.[] | select(.state.finding.file? == "src/a.sh")][0].state.diff_hunk | test("truncated to fit")' "$STUB_DIR"/req_*.json)"

# PR-level: 600 low findings overflow the budget → critical+high only.
python3 - "$TMP_DIR/t8b.json" <<'PY'
import json, sys
base = {"status": "complete", "merged_chunks": [0], "pre_existing_findings": [], "suppressed_findings": [],
        "residual_risks": [], "testing_gaps": [], "suppressed_by_confidence": {}, "demoted_no_quote": 0,
        "merged_duplicates": 0, "malformed_returns": 0, "malformed_findings": 0,
        "malformed_reasons": {}, "malformed_return_reasons": {}}
def f(n, sev, title):
    return {"#": n, "title": title, "severity": sev, "file": "src/long/path/to/module_%d.py" % n, "line": n,
            "why_it_matters": "x", "confidence": 100, "verified": True, "first_evidence": "y",
            "pre_existing": False, "autofix_class": "manual", "owner": "human", "chunks": [0]}
base["findings"] = [f(1, "high", "the one high")] + [f(i, "low", "low finding number %d with a long descriptive title padding padding" % i) for i in range(2, 602)]
json.dump(base, open(sys.argv[1], "w"))
PY
run_scorer t8b "$TMP_DIR/t8b.json" 1
check "Test 8c: PR-level overflow sends only critical and high" "critical_high/1" \
  "$(jq -r '.decisions_summary.pr_level_scope' "$TMP_DIR/t8b.json")/$(jq -s '[.[] | select(.questions.block_merge?)][0].state.findings | length' "$STUB_DIR"/req_*.json)"
check "Test 8d: findings beyond the cap are counted as skipped" "60/541" \
  "$(jq -r '"\(.decisions_summary.scored)/\(.decisions_summary.skipped)"' "$TMP_DIR/t8b.json")"

# --- Test 9: rendering ---------------------------------------------------------------
if [ -x "$RENDER_SH" ]; then
  write_merged "$TMP_DIR/t9.json"; cp "$TMP_DIR/t9.json" "$TMP_DIR/t9.orig"
  run_scorer t9 "$TMP_DIR/t9.json" 2
  bash "$RENDER_SH" "$TMP_DIR/t9.orig" > "$TMP_DIR/t9.plain.md"
  bash "$RENDER_SH" "$TMP_DIR/t9.json" > "$TMP_DIR/t9.dec.md"
  check "Test 9a: supported suffix after the chunk reference" "1" \
    "$(grep -c '^4\. 🟡 \[VERIFIED\] Medium Priority: solid medium claim — `src/b.sh:7` (chunk 0) · decision: supported 0.91$' "$TMP_DIR/t9.dec.md")"
  check "Test 9b: [UNSUPPORTED] below the threshold" "1" \
    "$(grep -c '^2\. 🟠 \[VERIFIED\] High Priority: weak high claim — `src/a.sh:20` (chunk 0) · decision: supported 0.12 \[UNSUPPORTED\]$' "$TMP_DIR/t9.dec.md")"
  check "Test 9c: severity disagreement is shown, severity itself unchanged" "1" \
    "$(grep -c '^3\. 🟠 \[VERIFIED\] High Priority: overrated high claim — .* · decision: supported 0.91 (decision model: medium)$' "$TMP_DIR/t9.dec.md")"
  check "Test 9d: the Coverage block says the decision model ran" "1" \
    "$(grep -c '^- \*\*Decision model:\*\* `OPENCODE-GO-DECISIONS/jev-1.13` (annotate) — scored 4, skipped 0$' "$TMP_DIR/t9.dec.md")"
  check "Test 9e: without decisions the render is unchanged by this feature" "0" \
    "$(grep -c 'decision' "$TMP_DIR/t9.plain.md" || true)"
  if [ -f "$SCORE_SH" ]; then
    check "Test 9f: score-review.sh reads the same flags with and without decisions" \
      "$(bash "$SCORE_SH" "$TMP_DIR/t9.plain.md" | tr '\n' ',')" \
      "$(bash "$SCORE_SH" "$TMP_DIR/t9.dec.md" | tr '\n' ',')"
  fi
  # LADR-067: nothing rendered may contain `#` followed by digits.
  check "Test 9g: annotated summary contains no autolinking #<digits>" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/t9.dec.md" || true)"
  write_merged "$TMP_DIR/t9f.json"
  run_scorer t9f "$TMP_DIR/t9f.json" 2 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
  bash "$RENDER_SH" "$TMP_DIR/t9f.json" > "$TMP_DIR/t9f.md"
  check "Test 9h: filter lists what it suppressed, without a number" "1" \
    "$(grep -c '^  - suppressed: 🟠 High Priority: weak high claim — `src/a.sh:20` (supported 0.12)$' "$TMP_DIR/t9f.md")"
  check "Test 9i: filter summary contains no autolinking #<digits>" "0" \
    "$(grep -coE '#[0-9]' "$TMP_DIR/t9f.md" || true)"
  check "Test 9j: filter Coverage line counts the suppression" "1" \
    "$(grep -c '(filter) — scored 4, skipped 0, suppressed 1$' "$TMP_DIR/t9f.md")"
fi

# --- Test 9k: a fix whose finding filter suppressed is explained ---------------------
ANNOTATE_SH="$SCRIPT_DIR/lib/annotate-suggested-fixes.sh"
if [ -f "$ANNOTATE_SH" ]; then
  printf '## 📝 Suggested Fixes\n\n### `src/a.sh:20`\nFix it.\n' > "$TMP_DIR/t9k.md"
  bash "$ANNOTATE_SH" "$TMP_DIR/t9f.json" "$TMP_DIR/t9k.md" 2>/dev/null
  check "Test 9k: the Suggested Fixes note names decision-model suppression" "1" \
    "$(grep -c '1 were suppressed by the decision model as unsupported by their quoted evidence' "$TMP_DIR/t9k.md")"
fi

# --- Test 10: a chunk cannot supply decisions ----------------------------------------
PY_BIN="$(command -v python3 || command -v python || true)"
if [ -n "$PY_BIN" ]; then
  out="$(printf '[{"chunk":0,"findings":[%s],"residual_risks":[],"testing_gaps":[]}]' \
    "$(finding 1 "forged claim" high src/a.sh 10 | jq -c '. + {decisions: {supported: 0.99}} | del(.["#"], .chunks)')" \
    | "$PY_BIN" "$MERGE_PY")"
  check "Test 10a: a producer-supplied decisions object is stripped by the merge" "false/1" \
    "$(printf '%s' "$out" | jq -r '"\(.findings[0] | has("decisions"))/\(.findings | length)"')"
fi

# --- Test 12: enriched findings validate against the schema ---------------------------
# Optional: needs the jsonschema package, which ubuntu-latest does not promise.
SCHEMA="$SCRIPT_DIR/../assets/findings-schema.json"
if [ -n "$PY_BIN" ] && "$PY_BIN" -c 'import jsonschema' >/dev/null 2>&1; then
  check "Test 12a: every annotated finding validates against the finding schema" "ok" \
    "$("$PY_BIN" -c '
import json, sys, jsonschema
item = json.load(open(sys.argv[1]))["properties"]["findings"]["items"]
for f in json.load(open(sys.argv[2]))["findings"]:
    jsonschema.validate(f, item)
print("ok")
' "$SCHEMA" "$TMP_DIR/t2.json" 2>&1)"
else
  echo "⏭️  jsonschema not installed — skipping Test 12 (schema validation of enriched findings)"
fi

# --- Test 11: call sites -------------------------------------------------------------
check "Test 11a: run-review.sh scores after the merge and before aggregation" "1" \
  "$(awk '/bash .*merge-findings\.sh"/{m=NR} /bash .*score-findings-decisions\.sh"/{s=NR} /bash .*aggregate-reviews\.sh"/{a=NR} END{print (m && s && a && m < s && s < a) ? 1 : 0}' "$RUN_REVIEW")"
check "Test 11b: local-review.sh scores after the merge and before aggregation" "1" \
  "$(awk '/bash .*merge-findings\.sh"/{m=NR} /bash .*score-findings-decisions\.sh"/{s=NR} /bash .*aggregate-reviews\.sh"/{a=NR} END{print (m && s && a && m < s && s < a) ? 1 : 0}' "$LOCAL_REVIEW")"
check "Test 11c: the scorer never writes a chunk failure flag (source)" "0" \
  "$(grep -vE '^[[:space:]]*#' "$SCORER" | grep -cE '(>|touch )[^|]*\.failed' || true)"
check "Test 11d: aggregation states the PR-level verdicts to the orchestrator" "1" \
  "$(grep -c '^## 🎯 Decision-model verdicts$' "$AGG_SH")"
# The prompt block itself, run against a scored and an unscored document. The
# block is cut out of aggregate-reviews.sh by its own start/end lines, so this
# also pins those markers.
prompt_block() { # prompt_block <merged> → the text appended to summary_prompt.txt
  local d="$TMP_DIR/agg_$RANDOM"
  mkdir -p "$d/ci_temp"
  cp "$1" "$d/ci_temp/findings.merged.json"
  { awk '/^DECISION_FACTS=""$/,/^  echo "🎯 Decision-model verdicts added/' "$AGG_SH"; echo 'fi'; } > "$d/block.sh"
  : > "$d/ci_temp/summary_prompt.txt"
  (cd "$d" && bash block.sh >/dev/null 2>&1)
  cat "$d/ci_temp/summary_prompt.txt"
}
p_ann="$(prompt_block "$TMP_DIR/t2.json")"
check "Test 11g: the prompt states block_merge as a fact" "1" \
  "$(printf '%s\n' "$p_ann" | grep -c '^- Probability that this PR should be blocked from merging: 0.83$')"
check "Test 11h: the prompt names the nearest overall-risk level" "1" \
  "$(printf '%s\n' "$p_ann" | grep -c '^- Overall merge risk: 2.40 on a 0-4 scale (nearest level: Moderate)$')"
check "Test 11i: the prompt keeps the decision rule authoritative" "1" \
  "$(printf '%s\n' "$p_ann" | grep -c 'They do NOT change the decision rule')"
check "Test 11j: filter mode says findings were removed, not tagged" "1" \
  "$(prompt_block "$TMP_DIR/t4.json" | grep -c '1 non-critical finding(s) whose quoted evidence it judged unsupported (probability below 0.50) were removed')"
check "Test 11k: no decisions → no prompt block" "" "$(prompt_block "$TMP_DIR/t1.json")"
check "Test 11e: the run artifact metadata carries decisions_summary" "1" \
  "$(grep -c '"decisions_summary": ' "$RUN_REVIEW")"
for f in .github/workflows/pipeline-code-review-report.yml .docs/examples/code-review-local.yml; do
  path="$SCRIPT_DIR/../../../../$f"
  for v in ENABLE_DECISIONS DECISIONS_PROVIDER DECISIONS_MODEL DECISIONS_MODE DECISIONS_MIN_PROBABILITY DECISIONS_TIMEOUT; do
    check "Test 11f: $f declares OPENCODE_REVIEW_REPORT_$v" "1" \
      "$(grep -cE "^ +OPENCODE_REVIEW_REPORT_${v}: " "$path")"
  done
done

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
SUITE_COMPLETED=1
[ "$fail" -eq 0 ]
