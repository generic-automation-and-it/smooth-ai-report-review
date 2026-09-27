#!/bin/bash
set -e

# Test script for LADR-097 — decision-model FIX/SKIP recommendations:
#   lib/review-findings-to-json.sh   — posted review body → scoreable findings
#   lib/recommend-fix-skip.sh        — scopes, the OPENCODE_ANALYSE_DECISIONS_*
#                                      namespace, annotate/filter, outputs
#   lib/score-findings-decisions.sh  — the internal fix/skip purpose
#   ai-analyse/scripts/lib/apply-decisions-to-scope.sh — annotate / withhold
#   ai-review/scripts/review-decisions.sh — `/ai-review --usedecisions`
#   pipeline-ai-analyse.yml          — the Variables and the call order
#
# Offline: `curl` and `gh` are PATH shims. The curl shim answers in the
# TypeSafe System One shape that test-score-findings-decisions.sh documents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TO_JSON="$SCRIPT_DIR/lib/review-findings-to-json.sh"
RECOMMEND="$SCRIPT_DIR/lib/recommend-fix-skip.sh"
SCORER="$SCRIPT_DIR/lib/score-findings-decisions.sh"
APPLY="$REPO_ROOT/.agents/skills/ai-analyse/scripts/lib/apply-decisions-to-scope.sh"
REVIEW_DECISIONS="$REPO_ROOT/.agents/skills/ai-review/scripts/review-decisions.sh"
ANALYSE_WF="$REPO_ROOT/.github/workflows/pipeline-ai-analyse.yml"

TMP_DIR="$(mktemp -d)"
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$TMP_DIR"; if [ "$SUITE_COMPLETED" != "1" ]; then echo ""; echo "❌ SUITE ABORTED EARLY (exit $rc) — assertions after this point never ran"; fi' EXIT

echo "=========================================="
echo "Testing recommend-fix-skip (LADR-097)"
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
  echo "⏭️  jq unavailable — skipping"
  SUITE_COMPLETED=1
  exit 0
fi

# --- shims -------------------------------------------------------------------------
BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'SHIM'
#!/bin/bash
out=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--max-time|-H) shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
n=1
while ! mkdir "$STUB_DIR/slot_$n" 2>/dev/null; do n=$((n + 1)); done
printf '%s' "$url" > "$STUB_DIR/url_$n"
cp "$data" "$STUB_DIR/req_$n.json"
[ "$STUB_MODE" = "http500" ] && { printf '{"error":{"message":"down"}}' > "$out"; printf '500'; exit 0; }
kind="$(jq -r '.questions | if has("preflight") then "preflight" elif has("block_merge") then "pr" else "finding" end' "$data")"
case "$kind" in
  preflight) printf '{"model":"jev-1.13","answers":{"preflight":{"noul":0.97}}}' > "$out" ;;
  pr) printf '{"model":"jev-1.13","answers":{"block_merge":{"noul":0.5},"dominant_risk":{"choice":"tests"},"overall_risk":{"score":1}}}' > "$out" ;;
  finding)
    jq -c '
      .state.finding.title as $t
      | { model: "jev-1.13",
          answers: ({
            supported: { noul: (if ($t | test("invalid")) then 0.2 else 0.9 end) },
            severity: { choice: "medium", probabilities: {} },
            pre_existing: { noul: 0.1 },
            actionability: { score: 1.64 } }
            + (if .questions | has("previously_skipped") then { previously_skipped: { noul: 0.83 } } else {} end)
            + (if .questions | has("sanctioned") then { sanctioned: { noul: 0.07 } } else {} end)
            + (if (.questions | has("fix_skip")) | not then {}
               elif ($t | test("badfs")) then { fix_skip: { choice: "maybe" } }
               elif ($t | test("invalid")) then { fix_skip: { choice: "skip_invalid", probabilities: { fix: 0.1, skip_intentional: 0.1, skip_invalid: 0.7, skip_deferred: 0.1 }, confidence: 0.6 } }
               elif ($t | test("intent")) then { fix_skip: { choice: "skip_intentional", probabilities: { fix: 0.45, skip_intentional: 0.5, skip_invalid: 0.05, skip_deferred: 0 } } }
               elif ($t | test("edge")) then { fix_skip: { choice: "skip_invalid", probabilities: { fix: 0.505, skip_intentional: 0, skip_invalid: 0.495, skip_deferred: 0 } } }
               elif ($t | test("nodist")) then { fix_skip: { choice: "skip_deferred" } }
               else { fix_skip: { choice: "fix", probabilities: { fix: 0.8, skip_intentional: 0.1, skip_invalid: 0.05, skip_deferred: 0.05 } } } end)) }' "$data" > "$out" ;;
esac
# STUB_FS_CONF: the model's own confidence on every fix/skip answer.
if [ -n "${STUB_FS_CONF:-}" ] && [ "$kind" = "finding" ]; then
  jq -c --argjson c "$STUB_FS_CONF" 'if .answers.fix_skip then .answers.fix_skip.confidence = $c else . end' "$out" > "$out.t" && mv "$out.t" "$out"
fi
printf '200'
SHIM
chmod +x "$BIN/curl"

# gh: reviews/comments timeline, pr diff, pr view, run download.
cat > "$BIN/gh" <<'SHIM'
#!/bin/bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$1 $2" in
  "api --paginate")
    case "$3" in
      *pulls/*/reviews) jq -n --rawfile b "$GH_BODY" '[{submitted_at:"2026-09-01T00:00:00Z", user:{login:"someone"}, body:"## 🔍 Issues Summary\n\n### 🟡 Medium Priority Issues\n\n9. 🟡 [VERIFIED] Medium Priority: human — `x:1`"},
                                                       {submitted_at:"2026-09-02T00:00:00Z", user:{login:"github-actions[bot]"}, body:$b}]' ;;
      *) echo '[]' ;;
    esac ;;
  "pr diff") cat "$GH_DIFF" ;;
  "pr view") printf '## Skip Areas / Known Issues\n\n- **2.** src/b.sh:7 — kept on purpose — **skip reason:** intentional\n\n## Other\n' ;;
  "run download")
    dir=""; while [ $# -gt 0 ]; do [ "$1" = "-D" ] && dir="$2"; shift; done
    [ -n "$GH_ARTIFACT" ] || exit 1
    mkdir -p "$dir"; cp "$GH_ARTIFACT" "$dir/findings.merged.json" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$BIN/gh"

# --- fixtures ------------------------------------------------------------------------
BODY="$TMP_DIR/body.md"
cat > "$BODY" <<'EOF'
## 📋 Summary

Prose.

## 🔍 Issues Summary

### 🔴 Critical Issues

None found

### 🟠 High Priority Issues

1. 🟠 [VERIFIED] High Priority (decision score 91% · rule-allowed 4%): Unchecked null — deref — `src/a.sh:20` (chunk 0)
   - Crashes on empty list.

### 🟡 Medium Priority Issues

2. 🟡 [SPECULATIVE] Medium Priority: intent pattern — `src/b.sh:7-9` (chunks 0, 1) · decision model rates it Low Priority
3. 🟡 [VERIFIED] Medium Priority: invalid claim — `src/a.sh:3` (chunk 1)
   - Docs say X.
   - second continuation
- **T1)** 🟡 Testing gap: nothing covers rollback

### 🔵 Low Priority / Nitpicks

4. 🔵 [VERIFIED] Low Priority: nodist rename — `src/c.py:1` (chunk 0)
5. 🔵 [VERIFIED] Low Priority: invalid but unlocated — `nowhere/x.sh:1` (chunk 0)
6. 🔵 [VERIFIED] Low Priority: badfs answer — `src/c.py:2` (chunk 0)

### 📊 Coverage

- stuff

## 📂 Detailed

7. 🔵 [VERIFIED] Low Priority: must not parse — `x:1`

<!-- ai-review-report run=424242 -->
EOF

DIFF="$TMP_DIR/pr_diff.txt"
cat > "$DIFF" <<'D'
diff --git a/src/a.sh b/src/a.sh
--- a/src/a.sh
+++ b/src/a.sh
@@ -1,3 +1,4 @@
 one
+two
 three
@@ -15,4 +16,6 @@
 keep
+added line twenty
 keep
diff --git a/src/b.sh b/src/b.sh
--- a/src/b.sh
+++ b/src/b.sh
@@ -6,2 +6,3 @@
 b-context
+b-added
diff --git a/src/c.py b/src/c.py
--- a/src/c.py
+++ b/src/c.py
@@ -1,1 +1,2 @@
+import os
 x = 1
D

ART="$TMP_DIR/artifact.json"
cat > "$ART" <<'J'
{"status":"complete","findings":[
 {"#":3,"file":"src/a.sh","title":"invalid claim","evidence":["src/a.sh:3 -- three"],"first_evidence":"src/a.sh:3 -- three","chunks":[1]},
 {"#":4,"file":"src/OTHER.py","title":"nodist rename","evidence":["wrong finding"]},
 {"#":2,"file":"src/b.sh","title":"a different title","evidence":["wrong finding"]}]}
J

# run_rec <case> <scope> [env...] — recommend-fix-skip with the shims; stdout in
# $TMP_DIR/<case>.log, outputs in $TMP_DIR/out_<case>.
run_rec() {
  local name="$1" scope="$2"
  shift 2
  export STUB_DIR="$TMP_DIR/stub_$name"
  rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
  env PATH="$BIN:$PATH" STUB_DIR="$STUB_DIR" STUB_MODE="${STUB_MODE:-ok}" _DECISIONS_RETRY_DELAY=0 \
    OPENCODE_GO_OPENAI_API_KEY=go-key OPENCODE_OPENROUTER_API_KEY=or-key \
    "$@" bash "$RECOMMEND" --scope "$scope" --review "$BODY" --out-dir "$TMP_DIR/out_$name" \
      --diff "$DIFF" ${REC_EXTRA:-} > "$TMP_DIR/$name.log" 2>&1
}
calls() { find "$STUB_DIR" -maxdepth 1 -name 'req_*.json' | wc -l | tr -d ' '; }
finding_reqs() { for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.state.finding) ' "$f"; done; }

# --- 1. review-findings-to-json ------------------------------------------------------
echo "--- review body → findings ---"
doc="$(bash "$TO_JSON" "$BODY")"
check "Test 1a: every numbered Issues Summary finding is parsed, detailed sections ignored" "1,2,3,4,5,6" \
  "$(printf '%s' "$doc" | jq -r '[.findings[]["#"]] | map(tostring) | join(",")')"
check "Test 1b: severity, title (with an inner em dash), file and line come from the label" \
  '{"#":1,"severity":"high","title":"Unchecked null — deref","file":"src/a.sh","line":20,"verified":true,"why_it_matters":"Crashes on empty list."}' \
  "$(printf '%s' "$doc" | jq -c '.findings[0]')"
check "Test 1c: a line range survives as a string, SPECULATIVE is unverified, no why when none rendered" \
  '{"#":2,"severity":"medium","title":"intent pattern","file":"src/b.sh","line":"7-9","verified":false}' \
  "$(printf '%s' "$doc" | jq -c '.findings[1]')"
check "Test 1d: severity filter keeps only medium and low" "2,3,4,5,6" \
  "$(bash "$TO_JSON" "$BODY" "" "medium,low" | jq -r '[.findings[]["#"]] | map(tostring) | join(",")')"
check "Test 1e: testing gaps and residual risks are not findings" "0" \
  "$(printf '%s' "$doc" | jq '[.findings[] | select(.title | test("rollback"))] | length')"
enriched="$(bash "$TO_JSON" "$BODY" "$ART" "medium,low")"
check "Test 1f: the artifact enriches only a finding with the same number, file AND title" "3" \
  "$(printf '%s' "$enriched" | jq -r '[.findings[] | select(.enriched_from_artifact) | .["#"]] | map(tostring) | join(",")')"
check "Test 1g: the enrichment carries the quoted evidence" "src/a.sh:3 -- three" \
  "$(printf '%s' "$enriched" | jq -r '.findings[] | select(.["#"] == 3) | .first_evidence')"
check "Test 1h: a mismatched artifact entry adds nothing (same number, other file / other title)" "0" \
  "$(printf '%s' "$enriched" | jq '[.findings[] | select(.["#"] == 2 or .["#"] == 4) | select(.evidence)] | length')"
check "Test 1i: source records the enrichment" "review_body+artifact" "$(printf '%s' "$enriched" | jq -r .source)"
printf '### 🟡 Medium Priority Issues\n\n- **[VERIFIED] Medium Priority**: orchestrator shape — `a:1`\n' > "$TMP_DIR/orch.md"
check "Test 1j: an orchestrator-written summary yields no findings (fail open)" "0" \
  "$(bash "$TO_JSON" "$TMP_DIR/orch.md" | jq '.findings | length')"
check "Test 1k: a missing file yields an empty, valid document" "complete 0" \
  "$(bash "$TO_JSON" "$TMP_DIR/nope.md" | jq -r '"\(.status) \(.findings | length)"')"
check "Test 1l: the bare Medium/Low sections the guard extracts parse too" "2,3" \
  "$(awk '/^### 🟡 Medium/,/^### 🔵/' "$BODY" > "$TMP_DIR/sections.md"; bash "$TO_JSON" "$TMP_DIR/sections.md" | jq -r '[.findings[]["#"]] | map(tostring) | join(",")')"

# --- 2. analyse scope off --------------------------------------------------------------
echo ""
echo "--- analyse scope: off by default ---"
run_rec off analyse
check "Test 2a: analyse without OPENCODE_ANALYSE_ENABLE_DECISIONS → status off" "off" "$(cat "$TMP_DIR/out_off/status")"
check "Test 2b: …and no request was sent" "0" "$(calls)"
run_rec off_inherit analyse OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1
check "Test 2c: the gate's ENABLE Variable is never inherited" "off" "$(cat "$TMP_DIR/out_off_inherit/status")"

# --- 3. analyse annotate ---------------------------------------------------------------
echo ""
echo "--- analyse scope: annotate ---"
REC_EXTRA="--severities medium,low --skip-areas $TMP_DIR/skips.md"
printf -- '- **2.** src/b.sh:7 — kept — **skip reason:** intentional\n' > "$TMP_DIR/skips.md"
run_rec ann analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1
check "Test 3a: status scored" "scored" "$(cat "$TMP_DIR/out_ann/status")"
check "Test 3b: only Medium/Low findings are sent (5 findings + preflight, no PR-level request)" "6" "$(calls)"
check "Test 3c: every finding request asks fix_skip with the four label classes" "5" \
  "$(finding_reqs | jq -s '[.[] | select(.questions.fix_skip.criteria | keys == ["fix","skip_deferred","skip_intentional","skip_invalid"])] | length')"
check "Test 3d: Skip Areas reach the judge (previously_skipped asked)" "5" \
  "$(finding_reqs | jq -s '[.[] | select(.questions.previously_skipped and (.state.pr_skip_areas | test("kept")))] | length')"
check "Test 3e: default provider/model when neither namespace sets one" "https://opencode.ai/zen/v1/systemone jev-1.13" \
  "$(cat "$STUB_DIR/url_1") $(jq -r .model "$STUB_DIR/req_1.json")"
tsv="$TMP_DIR/out_ann/recommendations.tsv"
check "Test 3f: a malformed fix_skip answer leaves that finding unscored (5 of 6 → 4 rows)" "2 3 4 5" \
  "$(awk -F '\t' 'NR > 1 { printf "%s%s", s, $1; s = " " }' "$tsv")"
check "Test 3g: recommendation, class and P(skip) = 1 - P(fix)" "SKIP intentional 55|SKIP invalid 90|SKIP deferred |SKIP invalid 90" \
  "$(awk -F '\t' 'NR > 1 { printf "%s%s %s %s", s, $3, $4, $5; s = "|" }' "$tsv")"
check "Test 3h: annotate writes no withhold list" "no" "$([ -e "$TMP_DIR/out_ann/withhold.txt" ] && echo yes || echo no)"
check "Test 3i: the table carries no # + digit (LADR-067)" "0" "$(grep -cE '#[0-9]' "$TMP_DIR/out_ann/recommendations.md" || true)"
check "Test 3j: the decision score below the threshold is marked weak quoted evidence" "1" \
  "$(grep -c '| 3\. .*20%, weak quoted evidence' "$TMP_DIR/out_ann/recommendations.md" || true)"
check "Test 3k: a finding with no diff hunk says so" "1" "$(grep -c '| 5\. .*(no diff hunk)' "$TMP_DIR/out_ann/recommendations.md" || true)"
check "Test 3l: the document records the fix/skip purpose and no PR-level scope" "fix_skip not_asked" \
  "$(jq -r '.decisions_summary | "\(.purpose) \(.pr_level_scope)"' "$TMP_DIR/out_ann/decisions.json")"
check "Test 3m: the key never reaches the table or the log" "0" \
  "$(cat "$TMP_DIR/ann.log" "$TMP_DIR/out_ann/recommendations.md" | grep -c 'go-key' || true)"

# --- 4. namespace mapping -------------------------------------------------------------
echo ""
echo "--- analyse namespace ---"
run_rec ns_own analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_PROVIDER=OPENROUTER-DECISIONS \
  OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13
check "Test 4a: an analyse provider without a model uses THAT provider's default, not the gate's model" \
  "https://openrouter.ai/api/alpha/decisions typesafe/jev-1.13" "$(cat "$STUB_DIR/url_1") $(jq -r .model "$STUB_DIR/req_1.json")"
run_rec ns_inherit analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENROUTER-DECISIONS \
  OPENCODE_REVIEW_REPORT_DECISIONS_MODEL='~typesafe/jev-latest'
check "Test 4b: with no analyse provider, provider AND model are inherited from the gate" \
  "https://openrouter.ai/api/alpha/decisions ~typesafe/jev-latest" "$(cat "$STUB_DIR/url_1") $(jq -r .model "$STUB_DIR/req_1.json")"
run_rec ns_timeout analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT=abc
check "Test 4c: the inherited timeout is validated by the scorer" "1" "$(grep -c "DECISIONS_TIMEOUT='abc'" "$TMP_DIR/ns_timeout.log" || true)"
run_rec ns_bad analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_PROVIDER=OPENAI
check "Test 4d: a chat provider is refused, best-effort (status unavailable, no request)" "unavailable 0" \
  "$(cat "$TMP_DIR/out_ns_bad/status") $(calls)"
check "Test 4e: …and the log says which namespace supplied it" "1" "$(grep -c 'OPENCODE_ANALYSE_DECISIONS_\* in use' "$TMP_DIR/ns_bad.log" || true)"

# --- 5. analyse filter ------------------------------------------------------------------
echo ""
echo "--- analyse scope: filter ---"
run_rec filt analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MODE=filter \
  OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=0.6
check "Test 5a: withheld = SKIP with P(skip) ≥ threshold and a found hunk (not 2 at 55%, not 4 without a distribution, not 5 without a hunk, not unscored 6)" \
  "3" "$(paste -sd ' ' - < "$TMP_DIR/out_filt/withhold.txt")"
run_rec filt_low analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MODE=FILTER \
  OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=.5
check "Test 5b: a lower threshold (and case-insensitive mode) withholds 2 as well" "2 3" "$(paste -sd ' ' - < "$TMP_DIR/out_filt_low/withhold.txt")"
run_rec filt_bad analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MODE=filter \
  OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=2
check "Test 5c: an invalid threshold falls back to 0.5" "2 3" "$(paste -sd ' ' - < "$TMP_DIR/out_filt_bad/withhold.txt")"
check "Test 5d: the table lists what was withheld, without #" "1" \
  "$(grep -c '^Withheld from the autonomous fixer (filter, P(skip) ≥ 60%): 3\.$' "$TMP_DIR/out_filt/recommendations.md" || true)"
BODY_SAVE="$BODY"; BODY="$TMP_DIR/edge.md"
printf '### 🟡 Medium Priority Issues\n\n1. 🟡 [VERIFIED] Medium Priority: edge claim — `src/a.sh:3` (chunk 0)\n' > "$BODY"
run_rec edge analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MODE=filter \
  OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=0.5
BODY="$BODY_SAVE"
check "Test 5e: the threshold compares the raw P(skip) — 0.495 shows as 50% but is not withheld at 0.5" "50|" \
  "$(awk -F '\t' 'NR == 2 { printf "%s", $5 }' "$TMP_DIR/out_edge/recommendations.tsv")|$(cat "$TMP_DIR/out_edge/withhold.txt")"

# PR 179 review 5331521317: the decision-score threshold is the gate's in every
# scope; the analyse MIN_PROBABILITY is only the P(skip) filter threshold.
REC_EXTRA="--severities medium,low"
run_rec thr_analyse analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=0.95
check "Test 5f: a high analyse P(skip) threshold does not mark a 90% decision score weak quoted evidence" "0|1" \
  "$(grep -c '| 2\. .*90%, weak quoted evidence' "$TMP_DIR/out_thr_analyse/recommendations.md" || true)|$(grep -c '| 3\. .*20%, weak quoted evidence' "$TMP_DIR/out_thr_analyse/recommendations.md" || true)"
run_rec thr_gate analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY=0.95
check "Test 5g: the gate's decision-score threshold decides weak quoted evidence in the analyse table" "1" \
  "$(grep -c '| 2\. .*90%, weak quoted evidence' "$TMP_DIR/out_thr_gate/recommendations.md" || true)"
check "Test 5h: the analyse job forwards the gate's decision-score threshold" "1" \
  "$(grep -c "OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY: \${{ vars.OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY || '0.5' }}" "$ANALYSE_WF" || true)"

# A fix/skip answer below the confidence floor is shown as uncertain, never
# withheld, and leans the way the model leaned (PR 179: the answers a human
# overturned came at confidence 0.12 and 0.14).
run_rec unsure analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MODE=filter \
  OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=0.5 STUB_FS_CONF=0.12
check "Test 5i: a low-confidence answer is UNCERTAIN in the TSV and is never withheld" "UNCERTAIN UNCERTAIN|" \
  "$(awk -F '\t' '$1 == 2 || $1 == 3 { printf "%s%s", s, $3; s = " " }' "$TMP_DIR/out_unsure/recommendations.tsv")|$(cat "$TMP_DIR/out_unsure/withhold.txt" 2>/dev/null)"
check "Test 5j: the table says which way it leans and how confident it was" "1" \
  "$(grep -c '| 3\. .*| uncertain — leans SKIP (invalid), confidence 12% |' "$TMP_DIR/out_unsure/recommendations.md" || true)"
section3="$(awk '/^### 🟡 Medium/{f=1} /^### 🔵/{f=0} f' "$BODY")"
check "Test 5k: ai-analyse's advisory line says uncertain, not recommends" "1|0" \
  "$(printf '%s' "$section3" | bash "$APPLY" "$TMP_DIR/out_unsure/recommendations.tsv" "" "$TMP_DIR/rep_unsure" | grep -c 'Decision model: uncertain, leans SKIP (invalid) (confidence 12%)')|$(printf '%s' "$section3" | bash "$APPLY" "$TMP_DIR/out_unsure/recommendations.tsv" "" "$TMP_DIR/rep_unsure2" | grep -c 'recommends SKIP (invalid)' || true)"
run_rec sure analyse OPENCODE_ANALYSE_ENABLE_DECISIONS=1 OPENCODE_ANALYSE_DECISIONS_MODE=filter \
  OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY=0.5 STUB_FS_CONF=0.3
check "Test 5l: at the floor (0.3) the answer counts, and filter withholds as before" "2 3" \
  "$(paste -sd ' ' - < "$TMP_DIR/out_sure/withhold.txt")"

# --- 6. review scope ---------------------------------------------------------------------
echo ""
echo "--- review scope (/ai-review --usedecisions) ---"
REC_EXTRA=""
run_rec rev review OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENROUTER-DECISIONS OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter
check "Test 6a: review scope needs no ENABLE Variable — the switch is the opt-in" "scored" "$(cat "$TMP_DIR/out_rev/status")"
check "Test 6b: …uses the gate's own provider Variable" "https://openrouter.ai/api/alpha/decisions" "$(cat "$STUB_DIR/url_1")"
check "Test 6c: …scores every severity (6 findings + preflight)" "7" "$(calls)"
check "Test 6d: …and never withholds, even with MODE=filter" "no" "$([ -e "$TMP_DIR/out_rev/withhold.txt" ] && echo yes || echo no)"
check "Test 6e: the analyse namespace does not leak into the review scope" "https://openrouter.ai/api/alpha/decisions" \
  "$(run_rec rev2 review OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENROUTER-DECISIONS OPENCODE_ANALYSE_DECISIONS_PROVIDER=OPENCODE-GO-DECISIONS; cat "$STUB_DIR/url_1")"

# --- 7. best-effort paths -----------------------------------------------------------------
echo ""
echo "--- best-effort ---"
STUB_MODE=http500 run_rec down review
check "Test 7a: a failed preflight → status unavailable, exit 0" "unavailable" "$(cat "$TMP_DIR/out_down/status")"
check "Test 7b: …and no table" "no" "$([ -e "$TMP_DIR/out_down/recommendations.md" ] && echo yes || echo no)"
BODY_SAVE="$BODY"; BODY="$TMP_DIR/orch.md"
run_rec none review
BODY="$BODY_SAVE"
check "Test 7c: no gate-numbered findings → status no_findings, no request" "no_findings 0" "$(cat "$TMP_DIR/out_none/status") $(calls)"
set +e
bash "$RECOMMEND" --scope nope --review "$BODY" --out-dir "$TMP_DIR/x" >/dev/null 2>&1; rc_scope=$?
bash "$RECOMMEND" --scope review >/dev/null 2>&1; rc_args=$?
set -e
check "Test 7d: usage errors exit 64" "64 64" "$rc_scope $rc_args"

# --- 8. the gate path is unchanged ----------------------------------------------------------
echo ""
echo "--- gate path unchanged ---"
bash "$TO_JSON" "$BODY" > "$TMP_DIR/gate.json"
export STUB_DIR="$TMP_DIR/stub_gate"; mkdir -p "$STUB_DIR"
env PATH="$BIN:$PATH" STUB_DIR="$STUB_DIR" STUB_MODE=ok OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 \
  OPENCODE_GO_OPENAI_API_KEY=go-key bash "$SCORER" "$TMP_DIR/gate.json" "$TMP_DIR/none" 1 "$DIFF" >/dev/null 2>&1
check "Test 8a: without the internal switch no request asks fix_skip" "0" \
  "$(for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.questions.fix_skip)' "$f"; done | wc -l | tr -d ' ')"
check "Test 8b: …the PR-level request is still sent" "1" \
  "$(for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.questions.block_merge)' "$f"; done | wc -l | tr -d ' ')"
check "Test 8c: …and the summary carries no purpose key" "false" "$(jq '.decisions_summary | has("purpose")' "$TMP_DIR/gate.json")"

# --- 9. apply-decisions-to-scope ---------------------------------------------------------------
echo ""
echo "--- ai-analyse scope filter ---"
section="$(awk '/^### 🟡 Medium/{f=1; next} /^### /{f=0} f' "$BODY")"
out="$(printf '%s' "$section" | bash "$APPLY" "$tsv" "" "$TMP_DIR/rep_ann")"
check "Test 9a: annotate inserts one advisory line directly under a scored finding" \
  "   - 🎯 Decision model: recommends SKIP (invalid) — P(skip) 90% · decision score 20%, weak quoted evidence · previously skipped 83% · actionability 1.6 of 2 (advisory)" \
  "$(printf '%s\n' "$out" | awk '/^3\. /{getline; print}')"
check "Test 9b: …and keeps every original line" "$(printf '%s\n' "$section" | grep -c .)" \
  "$(printf '%s\n' "$out" | grep -v '🎯 Decision model' | grep -c .)"
check "Test 9c: annotate withholds nothing (count 0)" "0" "$(cat "$TMP_DIR/rep_ann.count")"
printf '3\n' > "$TMP_DIR/wh.txt"
out="$(printf '%s' "$section" | bash "$APPLY" "$tsv" "$TMP_DIR/wh.txt" "$TMP_DIR/rep_f" 2>"$TMP_DIR/apply.err")"
check "Test 9d: filter removes the finding and its continuation lines, keeps the next item" \
  "2. 🟡 [SPECULATIVE] Medium Priority: intent pattern — \`src/b.sh:7-9\` (chunks 0, 1) · decision model rates it Low Priority|   - 🎯 Decision model: recommends SKIP (intentional) — P(skip) 55% · decision score 90% · previously skipped 83% · actionability 1.6 of 2 (advisory)|- **T1)** 🟡 Testing gap: nothing covers rollback" \
  "$(printf '%s\n' "$out" | grep . | paste -sd '|' -)"
check "Test 9e: the withheld report holds the finding verbatim, and the canonical count" "3|1" \
  "$(grep -c . "$TMP_DIR/rep_f" | tr -d ' ')|$(cat "$TMP_DIR/rep_f.count")"
check "Test 9f: the withhold is announced on stderr" "1" "$(grep -c 'Withheld 1 finding' "$TMP_DIR/apply.err" || true)"
low_section="$(awk '/^### 🔵 Low/{f=1; next} /^### /{f=0} f' "$BODY")"
printf '5\n' > "$TMP_DIR/wh5.txt"
out="$(printf '%s' "$low_section" | bash "$APPLY" "$tsv" "$TMP_DIR/wh5.txt" "$TMP_DIR/rep_gap" 2>/dev/null)"
check "Test 9f2: a gap left by a withheld item turns survivors into bold literal numbers (CommonMark would renumber 6 as 5)" \
  "- **4.** 🔵|- **6.** 🔵" "$(printf '%s\n' "$out" | grep -oE '^- \*\*[0-9]+\.\*\* 🔵' | paste -sd '|' -)"
check "Test 9f3: without a gap the ordered list is left as rendered" "2" \
  "$(printf '%s' "$section" | bash "$APPLY" "$tsv" "$TMP_DIR/wh.txt" "$TMP_DIR/rep_nogap" 2>/dev/null | grep -cE '^(2\. |- \*\*T1\)\*\*)')"
check "Test 9g: no recommendations → byte-identical pass-through" "$section" \
  "$(printf '%s' "$section" | bash "$APPLY" "$TMP_DIR/missing.tsv" "" "$TMP_DIR/rep_none")"
check "Test 9h: …with a zero count" "0" "$(cat "$TMP_DIR/rep_none.count")"

# --- 10. /ai-review --usedecisions helper -----------------------------------------------------------
echo ""
echo "--- review-decisions.sh ---"
export STUB_DIR="$TMP_DIR/stub_rd"; mkdir -p "$STUB_DIR"
rd_out="$(env PATH="$BIN:$PATH" STUB_DIR="$STUB_DIR" STUB_MODE=ok GH_BODY="$BODY" GH_DIFF="$DIFF" GH_ARTIFACT="$ART" \
  _DECISIONS_RETRY_DELAY=0 OPENCODE_GO_OPENAI_API_KEY=go-key bash "$REVIEW_DECISIONS" 77 2>&1)"
check "Test 10a: fetches the latest gate review (not the human one) and prints the table" "1" \
  "$(printf '%s\n' "$rd_out" | grep -c '^| 3\. | 🟡 Medium | `src/a.sh:3` | SKIP (invalid) | 90% |' || true)"
check "Test 10b: the human-authored review with finding 9 was not used" "0" "$(printf '%s\n' "$rd_out" | grep -c '^| 9\.' || true)"
check "Test 10c: the run marker drives the artifact download" "1" "$(grep -c 'run download 424242 -n review-run-424242' "$STUB_DIR/gh.log" || true)"
check "Test 10d: …whose evidence reaches the judge" "1" \
  "$(for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.state.finding.first_evidence == "src/a.sh:3 -- three")' "$f"; done | wc -l | tr -d ' ')"
check "Test 10e: the PR's Skip Areas reach the judge" "6" \
  "$(for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.state.pr_skip_areas | tostring | test("skip reason"))' "$f"; done | wc -l | tr -d ' ')"
check "Test 10f: the scored JSON path is printed" "1" "$(printf '%s\n' "$rd_out" | grep -c '^Scored findings: .*/out/decisions.json$' || true)"
rd_miss="$(env PATH="$BIN:$PATH" AI_REVIEW_REPORT_DIR="$TMP_DIR/nowhere" bash "$REVIEW_DECISIONS" 77 2>&1; echo "rc=$?")"
check "Test 10g: a missing ai-review-report skill is explained, exit 0" "1 rc=0" \
  "$(printf '%s\n' "$rd_miss" | grep -c 'needs the ai-review-report skill' | tr -d ' ') $(printf '%s\n' "$rd_miss" | tail -n 1)"
set +e
bash "$REVIEW_DECISIONS" abc >/dev/null 2>&1; rc_rd=$?
set -e
check "Test 10h: a non-numeric PR is a usage error" "64" "$rc_rd"
rd_file="$(env PATH="$BIN:$PATH" STUB_DIR="$STUB_DIR" STUB_MODE=ok GH_BODY=/dev/null GH_DIFF="$DIFF" GH_ARTIFACT="" \
  _DECISIONS_RETRY_DELAY=0 OPENCODE_GO_OPENAI_API_KEY=go-key bash "$REVIEW_DECISIONS" 77 "$BODY" 2>&1)"
check "Test 10i: a body file is used as given; an expired artifact is explained" "1 1" \
  "$(printf '%s\n' "$rd_file" | grep -c '^| 1\. | 🟠 High' | tr -d ' ') $(printf '%s\n' "$rd_file" | grep -c 'not downloadable' | tr -d ' ')"

# --- 11. workflow wiring ------------------------------------------------------------------------------
echo ""
echo "--- pipeline-ai-analyse.yml ---"
for v in OPENCODE_ANALYSE_ENABLE_DECISIONS OPENCODE_ANALYSE_DECISIONS_PROVIDER OPENCODE_ANALYSE_DECISIONS_MODEL \
         OPENCODE_ANALYSE_DECISIONS_MODE OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY OPENCODE_ANALYSE_DECISIONS_TIMEOUT; do
  check "Test 11a: the analyse workflow declares ${v}" "1" "$(grep -cE "^      ${v}: \\$\\{\\{ vars\\.${v}" "$ANALYSE_WF" || true)"
done
for v in OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER OPENCODE_REVIEW_REPORT_DECISIONS_MODEL OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT; do
  check "Test 11b: the analyse workflow forwards the inherited ${v}" "1" "$(grep -cE "^      ${v}: \\$\\{\\{ vars\\.${v}" "$ANALYSE_WF" || true)"
done
# Invocations only (comments name the libs too): `bash "${…_SKILL_DIR}/…"` and
# the redirect that writes the prompt.
order="$(grep -nE 'bash "\$\{(ANALYSE|REVIEW)_SKILL_DIR\}/scripts/lib/(filter-failing-test-findings|recommend-fix-skip|apply-decisions-to-scope)\.sh"|\} > ci_temp/analyse_prompt\.md$' "$ANALYSE_WF" \
  | sed -E 's/.*(filter-failing-test-findings|recommend-fix-skip|apply-decisions-to-scope|analyse_prompt).*/\1/' | uniq | paste -sd ' ' -)"
check "Test 11c: failing-test filter → decision scoring → scope filter → prompt" \
  "filter-failing-test-findings recommend-fix-skip apply-decisions-to-scope analyse_prompt" "$order"
HARNESS_WF="$REPO_ROOT/.github/workflows/llm-eval-harness.yml"
scope_re="$(awk '/id: v2_scope/{f=1} f && /grep -qE/{print; exit}' "$HARNESS_WF" | sed -E "s/.*grep -qE '([^']*)'.*/\1/")"
for p in .agents/skills/ai-analyse/scripts/lib/apply-decisions-to-scope.sh .agents/skills/ai-review/scripts/review-decisions.sh \
         .agents/skills/ai-review-report/scripts/lib/recommend-fix-skip.sh; do
  check "Test 11e: a PR touching only ${p##*/} runs the blocking regression job" "1" \
    "$(printf '%s\n' "$p" | grep -cE "$scope_re" || true)"
done
check "Test 11d: the new libs are guarded, so a PR branch that predates them still analyses" "2" \
  "$(grep -cE '\[ -f "\$\{(REVIEW|ANALYSE)_SKILL_DIR\}/scripts/lib/(recommend-fix-skip|apply-decisions-to-scope)\.sh" \]' "$ANALYSE_WF" || true)"

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
SUITE_COMPLETED=1
[ "$fail" -eq 0 ]
