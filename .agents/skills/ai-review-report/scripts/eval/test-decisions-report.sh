#!/bin/bash
# Offline tests for the decision-model measurement leg of the eval harness
# (LADR-093 follow-up): lib/decisions-report.py and run-evals.sh's
# record_decisions. No model, no network — curl is a PATH shim.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/lib/decisions-report.py"
RUN_EVALS="$SCRIPT_DIR/run-evals.sh"
SKILL_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [ "$3" = "$2" ]; then echo "✅ $1"; pass=$((pass + 1))
  else echo "❌ $1"; echo "   expected: $2"; echo "   actual:   $3"; fail=$((fail + 1)); fi
}

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "⏭️  python3 or jq unavailable — skipping decision-measurement tests"
  exit 0
fi

echo "=========================================="
echo "Testing the decision-model measurement (eval)"
echo "=========================================="

# --- 1. the analyzer, on records with known ground truth ----------------------------
R="$TMP/records"; mkdir -p "$R"
f() { # f <severity> <verified> <title> <supported> <jev_severity> <jev_conf>
  printf '{"severity":"%s","verified":%s,"confidence":100,"title":"%s","why_it_matters":"w","supported":%s,"jev_severity":"%s","jev_confidence":%s,"diff_hunk_found":true}' "$@"
}
# DR fixture that RE-RAISED its false positive; Jev doubts it (0.10) and rates it low.
printf '{"fixture":"DR-900","kind":"must-not-flag","sample":1,"min_severity":"HIGH","forbidden_claim":"redundant( [[:alnum:]-]+){0,2} storage","status":"scored","provider":"P","model":"M","findings":[%s,%s]}' \
  "$(f high true 'Redundant hybrid storage layer' 0.10 low 0.9)" \
  "$(f medium true 'Unrelated naming nit' 0.70 low 0.5)" > "$R/DR-900.1.json"
# DR fixture that stayed clean.
printf '{"fixture":"DR-901","kind":"must-not-flag","sample":1,"min_severity":"HIGH","forbidden_claim":"langversion","status":"no_findings","provider":null,"model":null,"findings":[]}' > "$R/DR-901.1.json"
# MC fixtures: two real catches Jev supports; one it doubts (a recall risk for filter).
printf '{"fixture":"MC-900","kind":"must-catch","sample":1,"min_severity":"HIGH","forbidden_claim":"","status":"scored","provider":"P","model":"M","findings":[%s]}' \
  "$(f high true 'SQL injection' 0.95 critical 0.9)" > "$R/MC-900.1.json"
printf '{"fixture":"MC-901","kind":"must-catch","sample":1,"min_severity":"MEDIUM","forbidden_claim":"","status":"scored","provider":"P","model":"M","findings":[%s]}' \
  "$(f medium true 'Guard deleted' 0.40 medium 0.7)" > "$R/MC-901.1.json"
# A sample whose decisions failed must be excluded, not counted as clean.
printf '{"fixture":"MC-902","kind":"must-catch","sample":1,"min_severity":"HIGH","forbidden_claim":"","status":"unavailable","note":"⚠️ HTTP 401","findings":[]}' > "$R/MC-902.1.json"

out="$(python3 "$REPORT" "$R")"; rc=$?
check "1a: report exits 0" "0" "$rc"
check "1b: POSIX class in forbidden_claim is honoured (DR-002 shape)" "1" \
  "$(printf '%s\n' "$out" | grep -c 'known false positives (DR re-raises) : n=1 ')"
check "1c: true catches measured" "1" "$(printf '%s\n' "$out" | grep -c 'true catches (seeded defects)        : n=2 ')"
check "1d: separation — both catches outscore the false positive" "1" \
  "$(printf '%s\n' "$out" | grep -c 'separation (AUC, 1.0 = perfect, 0.5 = chance): 1.00')"
check "1e: an unavailable sample is excluded, and says so" "1" "$(printf '%s\n' "$out" | grep -c 'Excluded       : 1 sample')"
check "1f: base — 1 DR re-raise, 2 of 3 catches (MC-902 excluded)" "1" \
  "$(printf '%s\n' "$out" | grep -cE '^ +base +1/2 +2/2 ')"
check "1g: filter@0.50 removes the re-raise AND loses the doubted catch" "1" \
  "$(printf '%s\n' "$out" | grep -cE '^ +filter@0.50 +0/2 +1/2 .*precision \+1, RECALL -1')"
check "1h: filter@0.25 removes the re-raise with no recall loss" "1" \
  "$(printf '%s\n' "$out" | grep -cE '^ +filter@0.25 +0/2 +2/2 .*precision \+1$')"
check "1i: sev@0.80 downgrades the false positive out of flag range" "1" \
  "$(printf '%s\n' "$out" | grep -cE '^ +sev@0.80 +0/2 +2/2 ')"
check "1j: Jev severity — false positive rated below Medium" "1" \
  "$(printf '%s\n' "$out" | grep -c 'false positives Jev would rate below Medium : 1/1')"
check "1k: no records → says so, exit 0" "0/1" \
  "$(mkdir -p "$TMP/empty"; o="$(python3 "$REPORT" "$TMP/empty")"; echo "$?/$(printf '%s' "$o" | grep -c 'did not run')")"

# Rule-based policies, on records that carry `sanctioned` (rules were given).
R2="$TMP/records-rules"; mkdir -p "$R2"
fr() { # fr <severity> <title> <supported> <sanctioned>
  printf '{"severity":"%s","verified":true,"confidence":100,"title":"%s","why_it_matters":"w","supported":%s,"sanctioned":%s,"jev_severity":"medium","jev_confidence":0.5,"diff_hunk_found":true}' "$@"
}
# A policy-exempt false positive: well evidenced (0.85) but sanctioned (0.9).
printf '{"fixture":"DR-950","kind":"must-not-flag","sample":1,"min_severity":"HIGH","forbidden_claim":"langversion","status":"scored","findings":[%s]}' \
  "$(fr medium 'Missing LangVersion' 0.85 0.90)" > "$R2/DR-950.1.json"
# A hallucinated false positive: not sanctioned (0.3) but unsupported (0.1).
printf '{"fixture":"DR-951","kind":"must-not-flag","sample":1,"min_severity":"HIGH","forbidden_claim":"invalid","status":"scored","findings":[%s]}' \
  "$(fr high 'Invalid action ref' 0.10 0.30)" > "$R2/DR-951.1.json"
printf '{"fixture":"MC-950","kind":"must-catch","sample":1,"min_severity":"HIGH","forbidden_claim":"","status":"scored","findings":[%s]}' \
  "$(fr high 'SQL injection' 0.95 0.05)" > "$R2/MC-950.1.json"
out2="$(python3 "$REPORT" "$R2")"
check "1l: the sanctioned section appears when rules were given" "1" "$(printf '%s\n' "$out2" | grep -c '1b. `sanctioned`')"
check "1m: rules@0.50 removes only the policy-exempt false positive" "1" \
  "$(printf '%s\n' "$out2" | grep -cE '^ +rules@0.50 +1/2 +1/1 ')"
check "1n: either@0.50 removes both kinds without losing the catch" "1" \
  "$(printf '%s\n' "$out2" | grep -cE '^ +either@0.50 +0/2 +1/1 ')"
check "1o: without sanctioned values the rule policies are not printed" "0" \
  "$(printf '%s\n' "$out" | grep -cE '^ +(rules|either)@')"

# --- 2. record_decisions, end to end on a fake fixture sandbox ----------------------
# The function is cut out of run-evals.sh, so this exercises the real code, not
# a copy. It drives the REAL merge-findings.sh and score-findings-decisions.sh.
awk '/^record_decisions\(\) \{/{p=1} p{print} p && /^}$/{exit}' "$RUN_EVALS" > "$TMP/record.sh"
check "2a: record_decisions found in run-evals.sh" "1" "$(grep -c '^record_decisions() {' "$TMP/record.sh")"

SB="$TMP/sandbox"; mkdir -p "$SB/src" && cd "$SB" || exit 1
git init -q && git config user.email t@t && git config user.name t
git commit -q --allow-empty -m base
printf 'one\ntwo\n' > src/a.cs && git add -A && git commit -q -m head
mkdir -p ci_temp/reviews
echo "total_chunks=1" > ci_temp/github_output.txt
cat > ci_temp/reviews/chunk_0.findings.json <<'J'
{"chunk":0,"findings":[{"title":"Redundant storage copy","severity":"high","file":"src/a.cs","line":2,
 "why_it_matters":"w","confidence":100,"verified":true,"first_evidence":"src/a.cs:2 -- two",
 "pre_existing":false,"autofix_class":"manual","owner":"human"}],"residual_risks":[],"testing_gaps":[]}
J
cat > "$TMP/manifest.json" <<'J'
{"id":"DR-777","kind":"must-not-flag","label":"DR-777","forbidden_claim":"redundant storage"}
J
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
out=""; data=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -w|--max-time|-H) shift 2;; --data-binary) data="${2#@}"; shift 2;; -*) shift;; *) shift;; esac; done
if jq -e '.questions.preflight' "$data" >/dev/null 2>&1; then
  printf '{"model":"jev-1.13","answers":{"preflight":{"type":"noul","noul":0.9}}}' > "$out"
elif jq -e '.questions.block_merge' "$data" >/dev/null 2>&1; then
  printf '{"model":"jev-1.13","answers":{"block_merge":{"type":"noul","noul":0.2},"dominant_risk":{"type":"choice","choice":"maintainability","confidence":0.5},"overall_risk":{"type":"score","score":1.0,"confidence":0.5}}}' > "$out"
else
  printf '{"model":"jev-1.13","answers":{"supported":{"type":"noul","noul":0.07},"severity":{"type":"choice","choice":"low","probabilities":{},"confidence":0.88},"pre_existing":{"type":"noul","noul":0.1},"sanctioned":{"type":"noul","noul":0.2},"actionability":{"type":"score","score":0.4,"confidence":0.6}}}' > "$out"
fi
printf '200'
SHIM
chmod +x "$TMP/bin/curl"
mkdir -p "$TMP/decisions"
(
  export PATH="$TMP/bin:$PATH" OPENCODE_GO_OPENAI_API_KEY=k _DECISIONS_RETRY_DELAY=0
  # Read by the sourced record_decisions, not by this subshell directly.
  # shellcheck disable=SC2034
  DECISIONS_DIR="$TMP/decisions" SKILL_SCRIPTS_DIR="$SKILL_SCRIPTS_DIR" SELFTEST_SAMPLE=2
  # shellcheck disable=SC1091
  . "$TMP/record.sh"
  record_decisions "$TMP/manifest.json" "$SB"
)
rec="$TMP/decisions/DR-777.2.json"
check "2b: one record per fixture-sample" "true" "$([ -s "$rec" ] && echo true || echo false)"
check "2c: status scored, provider recorded" "scored/OPENCODE-GO-DECISIONS" "$(jq -r '"\(.status)/\(.provider)"' "$rec")"
check "2d: finding carries Jev's answers and the chunk's own tag" "0.07/low/0.88/true/high" \
  "$(jq -r '.findings[0] | "\(.supported)/\(.jev_severity)/\(.jev_confidence)/\(.verified)/\(.severity)"' "$rec")"
check "2e: manifest ground truth copied into the record" "must-not-flag/redundant storage/2" \
  "$(jq -r '"\(.kind)/\(.forbidden_claim)/\(.sample)"' "$rec")"
check "2f: annotate mode — the measured document lost nothing" "1" \
  "$(jq '.findings | length' "$SB/ci_temp/findings.merged.json")"
check "2g: the analyzer reads the real record" "1" \
  "$(python3 "$REPORT" "$TMP/decisions" | grep -c 'known false positives (DR re-raises) : n=1 ')"

# Provider failure → a record with a status and a note, never a crash.
rm -f "$SB/ci_temp/findings.merged.json" "$TMP/decisions"/*
(
  export PATH="$TMP/bin:$PATH" OPENCODE_GO_OPENAI_API_KEY=
  # Read by the sourced record_decisions, not by this subshell directly.
  # shellcheck disable=SC2034
  DECISIONS_DIR="$TMP/decisions" SKILL_SCRIPTS_DIR="$SKILL_SCRIPTS_DIR" SELFTEST_SAMPLE=1
  # shellcheck disable=SC1091
  . "$TMP/record.sh"
  record_decisions "$TMP/manifest.json" "$SB"
)
check "2h: a missing key records status unavailable with the reason" "unavailable/1" \
  "$(jq -r '"\(.status)/\(.note | test("OPENCODE_GO_OPENAI_API_KEY") | if . then 1 else 0 end)"' "$TMP/decisions/DR-777.1.json")"

# --- 2i. the shared record writer says what was actually measured -------------------
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/decision-record.sh"
W="$TMP/writer"; mkdir -p "$W"
mk() { # mk <out> <scored> <merged_chunks-json> [summary=yes|no] — a 2-finding merged doc
  jq -n --argjson scored "$2" --argjson mc "$3" --arg sum "${4:-yes}" '
    { status: "complete", merged_chunks: $mc,
      findings: [ {title:"a",severity:"high",verified:true,decisions:{supported:0.9}},
                  {title:"b",severity:"high",verified:true} ] }
    + (if $sum == "yes" then { decisions_summary: { provider: "P", model: "M", scored: $scored, skipped: (2 - $scored) } } else {} end)' > "$1"
}
st() { write_decision_record "$1" "$TMP/manifest.json" 1 "" "$2" /dev/null "$W/out.json"; jq -r '"\(.status)|\(.note)"' "$W/out.json"; }
mk "$W/full.json" 2 '[0]';          check "2i: every finding scored → scored" "scored|" "$(st "$W/full.json" 1)"
mk "$W/part.json" 1 '[0]';          check "2j: some findings unscored → partial, excluded" "partial|scored 1 of 2 findings" "$(st "$W/part.json" 1)"
mk "$W/pronly.json" 0 '[0]';        check "2k: only the PR-level answer succeeded → unavailable" "unavailable|no finding was scored" "$(st "$W/pronly.json" 1)"
mk "$W/cov.json" 2 '[0]';           check "2l: sidecars from fewer chunks than reviewed → partial_coverage" "partial_coverage|sidecars from 1 of 2 chunks" "$(st "$W/cov.json" 2)"
mk "$W/nosum.json" 0 '[0]' no;      check "2m: findings but no decisions at all → unavailable" "unavailable|no finding was scored" "$(st "$W/nosum.json" 1)"
check "2n: no merged document → no_merged" "no_merged|the merge produced no document" "$(st "$W/missing.json" 1)"
# The report names every excluded sample and why.
RX="$TMP/records-excluded"; mkdir -p "$RX"
cp "$R/DR-900.1.json" "$RX/"
write_decision_record "$W/part.json" "$TMP/manifest.json" 3 "stripped" 1 /dev/null "$RX/DR-777.3.json"
check "2o: the report names an excluded sample, its status and note" "1" \
  "$(python3 "$REPORT" "$RX" | grep -c -- '- DR-777 sample 3 (stripped): partial — scored 1 of 2 findings')"
check "2p: run-evals and calibrate both use the one writer" "2" \
  "$(grep -l 'write_decision_record' "$RUN_EVALS" "$SCRIPT_DIR/calibrate-decisions.sh" | wc -l | tr -d ' ')"

# --- 3. the measurement can never move the gate ------------------------------------
check "3a: recording happens only when EVAL_DECISIONS is on" "1" \
  "$(grep -c '\[ "\$DECISIONS_ON" = 1 \] && record_decisions' "$RUN_EVALS")"
check "3b: the report is printed after the verdict and never assigns fail" "0" \
  "$(awk '/Decision-model measurement: printed AFTER the verdict/{p=1} p' "$RUN_EVALS" | grep -cE '(^|[^_])fail=')"
check "3c: the report cannot abort the run" "1" \
  "$(grep -c 'decisions-report.py" "\$DECISIONS_DIR" || true' "$RUN_EVALS")"

# --- 4. planted findings and the calibration runner --------------------------------
CORPUS="$SCRIPT_DIR/corpus"
check "4a: every must-not-flag fixture plants a known false positive" "0" \
  "$(for m in "$CORPUS"/must-not-flag/*/manifest.json; do jq -e '.known_false_positive | type == "object"' "$m" >/dev/null || echo "$m"; done | grep -c . || true)"
check "4b: every must-catch fixture plants a known true positive" "0" \
  "$(for m in "$CORPUS"/must-catch/*/manifest.json; do jq -e '.known_true_positive | type == "object"' "$m" >/dev/null || echo "$m"; done | grep -c . || true)"
check "4c: every planted evidence line exists in its fixture file" "0" \
  "$(for m in "$CORPUS"/*/*/manifest.json; do
       jq -r '(.known_false_positive // .known_true_positive) | "\(.file)\t\(.evidence_line)"' "$m" \
         | while IFS=$'\t' read -r file ev; do grep -qF -- "$ev" "$(dirname "$m")/after/$file" || echo "$m"; done
     done | grep -c . || true)"
CAL="$TMP/cal"
( export PATH="$TMP/bin:$PATH" OPENCODE_GO_OPENAI_API_KEY=k _DECISIONS_RETRY_DELAY=0
  bash "$SCRIPT_DIR/calibrate-decisions.sh" "$CAL" > "$TMP/cal.log" 2>&1 )
check "4d: calibration scores 20 planted findings in each of three variants" "20/20/20" \
  "$(ls "$CAL/as-is" | wc -l | tr -d ' ')/$(ls "$CAL/stripped" | wc -l | tr -d ' ')/$(ls "$CAL/stripped+rules" | wc -l | tr -d ' ')"
check "4e: ground truth holds — all 14 planted FPs count as DR re-raises, all 6 TPs as catches (every variant)" "3" \
  "$(grep -cE '^ +base +14/14 +6/6 ' "$TMP/cal.log")"
# Code comments only: Markdown headings (DR-014 ships its LADR document, which
# is the point of that fixture) and C# directives such as `#nullable` are not
# comments and must survive.
check "4f: the stripped variant carries no code comments" "0" \
  "$( { find "$CAL"/work/stripped-* -path '*/.git' -prune -o -name '*.cs' -type f -print0 \
          | xargs -0 grep -hE '^[[:space:]]*//' ;
        find "$CAL"/work/stripped-* -path '*/.git' -prune -o \( -name '*.yml' -o -name '*.yaml' \) -type f -print0 \
          | xargs -0 grep -hE '^[[:space:]]*#' ; } 2>/dev/null | grep -c . || true)"
check "4f2: the as-is variant keeps them (the two variants really differ)" "true" \
  "$(find "$CAL"/work/as-is-* -path '*/.git' -prune -o -name '*.cs' -type f -print0 | xargs -0 grep -lE '^[[:space:]]*//' 2>/dev/null | grep -q . && echo true || echo false)"
check "4g: every planted finding quotes its code line (no line-not-found fallback)" "0" \
  "$(jq -r '.findings[0].first_evidence' "$CAL"/work/*/ci_temp/findings.merged.json | grep -cE ' -- $' || true)"
check "4i: only the rules variant sends project rules (the DR standards)" "0/20" \
  "$(cat "$CAL"/work/stripped-*/ci_temp/score.log >/dev/null 2>&1; jq -s '[.[] | select(.findings[0].sanctioned != null)] | length' "$CAL"/stripped/*.json)/$(jq -s '[.[] | select(.findings[0].sanctioned != null)] | length' "$CAL"/stripped+rules/*.json)"
check "4j: the rules report adds the sanctioned section and the rule policies" "1/1/1" \
  "$(grep -c '1b. `sanctioned`' "$TMP/cal.log")/$(grep -cE '^ +rules@0.50 ' "$TMP/cal.log")/$(grep -cE '^ +either@0.50 ' "$TMP/cal.log")"
( cd "$TMP" && export PATH="$TMP/bin:$PATH" OPENCODE_GO_OPENAI_API_KEY=k _DECISIONS_RETRY_DELAY=0 \
  && bash "$SCRIPT_DIR/calibrate-decisions.sh" rel-out > "$TMP/cal-rel.log" 2>&1 )
check "4k: a RELATIVE out_dir still collects every record (workers cd into sandboxes)" "60" \
  "$(ls "$TMP"/rel-out/as-is "$TMP"/rel-out/stripped "$TMP"/rel-out/stripped+rules 2>/dev/null | grep -c '\.json$')"
check "4h: run-evals runs the calibration only with the measurement, and it cannot abort" "1" \
  "$(grep -c 'calibrate-decisions.sh" "\${EVAL_ARTIFACT_DIR:+\$EVAL_ARTIFACT_DIR/calibration}" || true' "$RUN_EVALS")"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
