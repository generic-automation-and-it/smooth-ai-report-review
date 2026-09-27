#!/bin/bash
set -e

# Test script for LADR-098 — decisions hardening:
#   lib/score-findings-decisions.sh — fix_skip asked by the gate (optional)
#                                     vs the consumer purpose (required); the
#                                     code context (phase 4) and its budget
#                                     order; the findings_with_rules count
#   lib/review-diff.sh              — the diff as of the reviewed commit
#   lib/recommend-fix-skip.sh       — reusing the gate's answers, re-scoring
#                                     only the rest, with the artifact's rules
#   ai-review/scripts/review-decisions.sh — the run-id marker, the revision
#   run-review.sh / aggregate-reviews.sh  — the run artifact and the marker
#   eval: decision-record.sh, decisions-report.py, harvest-real-findings.sh
#   pipeline-ai-analyse.yml / llm-eval-harness.yml — the wiring
#
# Offline: curl and gh are PATH shims; the code context is read from a real
# throwaway git repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SCORER="$SCRIPT_DIR/lib/score-findings-decisions.sh"
REVIEW_DIFF="$SCRIPT_DIR/lib/review-diff.sh"
RECOMMEND="$SCRIPT_DIR/lib/recommend-fix-skip.sh"
REVIEW_DECISIONS="$REPO_ROOT/.agents/skills/ai-review/scripts/review-decisions.sh"
APPLY="$REPO_ROOT/.agents/skills/ai-analyse/scripts/lib/apply-decisions-to-scope.sh"
RUN_REVIEW="$SCRIPT_DIR/run-review.sh"
LOCAL_REVIEW="$SCRIPT_DIR/local-review.sh"
AGG_SH="$SCRIPT_DIR/aggregate-reviews.sh"
RECORD_SH="$SCRIPT_DIR/eval/lib/decision-record.sh"
REPORT_PY="$SCRIPT_DIR/eval/lib/decisions-report.py"
HARVEST="$SCRIPT_DIR/eval/harvest-real-findings.sh"
ANALYSE_WF="$REPO_ROOT/.github/workflows/pipeline-ai-analyse.yml"
HARNESS_WF="$REPO_ROOT/.github/workflows/llm-eval-harness.yml"

TMP_DIR="$(mktemp -d)"
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$TMP_DIR"; if [ "$SUITE_COMPLETED" != "1" ]; then echo ""; echo "❌ SUITE ABORTED EARLY (exit $rc) — assertions after this point never ran"; fi' EXIT

echo "=========================================="
echo "Testing decisions hardening (LADR-098)"
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

if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "⏭️  jq or git unavailable — skipping"
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
cp "$data" "$STUB_DIR/req_$n.json"
[ -z "${STUB_FAIL:-}" ] || { printf '{"error":{"message":"down"}}' > "$out"; printf '500'; exit 0; }
kind="$(jq -r '.questions | if has("preflight") then "preflight" elif has("block_merge") then "pr" else "finding" end' "$data")"
case "$kind" in
  preflight) printf '{"model":"jev-1.13","answers":{"preflight":{"noul":0.97}}}' > "$out" ;;
  pr) printf '{"model":"jev-1.13","answers":{"block_merge":{"noul":0.4},"dominant_risk":{"choice":"tests"},"overall_risk":{"score":1}}}' > "$out" ;;
  finding)
    jq -c --arg m "${STUB_MODEL:-jev-1.13}" '
      .state.finding.title as $t
      | { model: $m,
          answers: ({
            supported: { noul: 0.8 },
            severity: { choice: "medium", probabilities: {} },
            pre_existing: { noul: 0.1 },
            actionability: { score: 1.5 } }
            + (if .questions | has("sanctioned") then { sanctioned: { noul: 0.2 } } else {} end)
            + (if .questions | has("previously_skipped") then { previously_skipped: { noul: 0.3 } } else {} end)
            + (if (.questions | has("fix_skip")) | not then {}
               elif ($t | test("badfs")) then { fix_skip: { choice: "maybe" } }
               elif ($t | test("skipme")) then { fix_skip: { choice: "skip_invalid", probabilities: { fix: 0.1, skip_invalid: 0.9 } } }
               else { fix_skip: { choice: "fix", probabilities: { fix: 0.75, skip_invalid: 0.25 } } } end)) }' "$data" > "$out" ;;
esac
printf '200'
SHIM
chmod +x "$BIN/curl"

# gh: PR head/base, the current and the compared diff, commits, artifacts and
# the review timeline. GH_HEAD / GH_COMPARE_FAIL / GH_ARTIFACT_DIR / GH_BODY steer it.
cat > "$BIN/gh" <<'SHIM'
#!/bin/bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefOid*) printf '{"headRefOid":"%s","baseRefName":"main"}' "${GH_HEAD:-}" ;;
      *) cat "${GH_PR_BODY:-/dev/null}" ;;
    esac ;;
  "pr diff") cat "$GH_CURRENT_DIFF" ;;
  "run download")
    dir=""; while [ $# -gt 0 ]; do [ "$1" = "-D" ] && dir="$2"; shift; done
    [ -n "${GH_ARTIFACT_DIR:-}" ] || exit 1
    mkdir -p "$dir"; cp -R "$GH_ARTIFACT_DIR/." "$dir/" ;;
  "api --paginate")
    case "$3" in
      *pulls/*/reviews) jq -n --rawfile b "$GH_BODY" '[{submitted_at:"2026-09-02T00:00:00Z", user:{login:"github-actions[bot]"}, body:$b}]' ;;
      *) echo '[]' ;;
    esac ;;
  "api repos/{owner}/{repo}/commits/"*)
    printf '%s\n' "${GH_FULL_SHA:-}"; [ -n "${GH_FULL_SHA:-}" ] ;;
  "api -H")
    [ -z "${GH_COMPARE_FAIL:-}" ] || exit 1
    printf '%s\n' "$*" >> "$STUB_DIR/compare.log"
    cat "$GH_REVIEWED_DIFF" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$BIN/gh"

reset_stub() { export STUB_DIR="$TMP_DIR/stub_$1"; rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"; }
calls() { find "$STUB_DIR" -maxdepth 1 -name 'req_*.json' | wc -l | tr -d ' '; }
finding_reqs() { for f in "$STUB_DIR"/req_*.json; do [ -f "$f" ] && jq -c 'select(.state.finding)' "$f"; done; }
scorer() { # scorer <merged> [rules] [skip_areas] — env passes through
  env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
    _DECISIONS_RETRY_DELAY=0 bash "$SCORER" "$1" "$TMP_DIR/no_reviews" 1 "$DIFF" "${2:-}" "${3:-}"
}

# --- a real repository for the code context ------------------------------------------
SB="$TMP_DIR/sb"
mkdir -p "$SB/src"
(
  cd "$SB"
  git init -q && git config user.email t@t && git config user.name t
  for i in $(seq 1 60); do echo "line $i of a"; done > src/a.sh
  for i in $(seq 1 10); do echo "line $i of b"; done > src/b.sh
  git add -A && git commit -qm base
  sed -i.bak 's/^line 20 of a$/line 20 of a CHANGED/' src/a.sh && rm -f src/a.sh.bak
  sed -i.bak 's/^line 5 of b$/line 5 of b CHANGED/' src/b.sh && rm -f src/b.sh.bak
  git commit -qam head
  git diff HEAD~1..HEAD > "$TMP_DIR/pr_diff.txt"
)
DIFF="$TMP_DIR/pr_diff.txt"
HEAD_SHA="$(git -C "$SB" rev-parse HEAD)"
cat > "$TMP_DIR/graph.json" <<J
{"changed_functions":[{"name":"do_thing","qualified_name":"a.do_thing","file_path":"$SB/src/a.sh","line_start":15,"line_end":25,"risk_score":0.82,"is_test":false}]}
J

merged_doc() { # merged_doc <out> <finding-json>...
  local out="$1"; shift
  jq -n --argjson f "$(printf '%s\n' "$@" | jq -s '.')" \
    '{status:"complete", merged_chunks:[0], findings:$f, residual_risks:[], testing_gaps:[], pre_existing_findings:[]}' > "$out"
}
F1='{"#":1,"title":"gate alpha","severity":"medium","file":"src/a.sh","line":20,"why_it_matters":"It also breaks src/b.sh:5.","verified":true,"chunks":[0]}'
F2='{"#":2,"title":"badfs gate","severity":"low","file":"src/a.sh","line":20,"why_it_matters":"Low.","verified":true,"chunks":[0]}'

# --- 1. the gate asks fix_skip optionally --------------------------------------------
echo "--- the gate asks fix_skip, optionally ---"
reset_stub gate
merged_doc "$TMP_DIR/gate.json" "$F1" "$F2"
(cd "$SB" && _DECISIONS_ASK_FIX_SKIP=1 scorer "$TMP_DIR/gate.json" > "$TMP_DIR/gate.log" 2>&1)
check "Test 1a: every finding request asks fix_skip" "2" \
  "$(finding_reqs | jq -s '[.[] | select(.questions.fix_skip)] | length')"
check "Test 1b: the PR-level request is still sent" "1" \
  "$(for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.questions.block_merge)' "$f"; done | wc -l | tr -d ' ')"
check "Test 1c: an unusable fix_skip answer keeps the finding scored, with fix_skip null" "0.8 null" \
  "$(jq -r '.findings[1].decisions | "\(.supported) \(.fix_skip)"' "$TMP_DIR/gate.json")"
check "Test 1d: a usable answer is stored with its unrounded P(skip)" "fix 0.25" \
  "$(jq -r '.findings[0].decisions.fix_skip | "\(.choice) \(.skip_probability)"' "$TMP_DIR/gate.json")"
# The provider returns a dated snapshot for the configured id; both are kept so
# consumers can compare configuration with configuration (reuse fix, PR 179).
merged_doc "$TMP_DIR/snap.json" "$F1"
reset_stub snap
(cd "$SB" && STUB_MODEL=jev-1.13-20260917 scorer "$TMP_DIR/snap.json" >/dev/null 2>&1)
check "Test 1d2: a finding and the summary keep the returned snapshot AND the requested id" "jev-1.13-20260917 jev-1.13|jev-1.13" \
  "$(jq -r '.findings[0].decisions | "\(.model) \(.requested_model)"' "$TMP_DIR/snap.json")|$(jq -r '.decisions_summary.requested_model' "$TMP_DIR/snap.json")"
check "Test 1e: the gate document records the question, not the consumer purpose" "true false" \
  "$(jq -r '.decisions_summary | "\(.context.fix_skip_asked) \(has("purpose"))"' "$TMP_DIR/gate.json")"
reset_stub gate_filter
merged_doc "$TMP_DIR/gate_f.json" "$F1"
(cd "$SB" && _DECISIONS_ASK_FIX_SKIP=1 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter scorer "$TMP_DIR/gate_f.json" >/dev/null 2>&1)
check "Test 1f: asking fix_skip does not force annotate on the gate (filter stays filter)" "filter" \
  "$(jq -r '.decisions_summary.mode' "$TMP_DIR/gate_f.json")"
reset_stub purpose
merged_doc "$TMP_DIR/purpose.json" "$F1" "$F2"
(cd "$SB" && _DECISIONS_PURPOSE=fix_skip OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter scorer "$TMP_DIR/purpose.json" >/dev/null 2>&1)
check "Test 1g: the consumer purpose requires fix_skip (the badfs finding is unscored), forces annotate, skips PR-level" \
  "false|annotate|not_asked|fix_skip|0" \
  "$(jq -r '.findings[1] | has("decisions")' "$TMP_DIR/purpose.json")|$(jq -r '.decisions_summary | "\(.mode)|\(.pr_level_scope)|\(.purpose)"' "$TMP_DIR/purpose.json")|$(for f in "$STUB_DIR"/req_*.json; do jq -c 'select(.questions.block_merge)' "$f"; done | wc -l | tr -d ' ')"

# --- 2. code context (phase 4) ---------------------------------------------------------
echo ""
echo "--- code context ---"
ctx_of() { finding_reqs | jq -rs "map(select(.state.finding.title == \"$1\")) | first | .state.code_context // \"<none>\""; }
reset_stub ctx
merged_doc "$TMP_DIR/ctx.json" "$F1"
(cd "$SB" && _DECISIONS_SOURCE_REV="$HEAD_SHA" _DECISIONS_GRAPH_JSON="$TMP_DIR/graph.json" scorer "$TMP_DIR/ctx.json" >/dev/null 2>&1)
ctx="$(ctx_of "gate alpha")"
check "Test 2a: the enclosing function comes from the code graph range" "1" \
  "$(printf '%s\n' "$ctx" | grep -c 'Enclosing function `a.do_thing` (lines 15-25 of `src/a.sh`, code-graph risk 0.82)')"
check "Test 2b: its lines are numbered as in the file, at the reviewed revision" "1|1|0" \
  "$(printf '%s\n' "$ctx" | grep -c '^    20 | line 20 of a CHANGED$')|$(printf '%s\n' "$ctx" | grep -c '^    25 | ')|$(printf '%s\n' "$ctx" | grep -c '^    26 | ')"
check "Test 2c: another changed file the finding names brings its hunk" "1|1" \
  "$(printf '%s\n' "$ctx" | grep -c 'Hunk of `src/b.sh`, another changed file')|$(printf '%s\n' "$ctx" | grep -c '^+line 5 of b CHANGED$')"
check "Test 2d: the finding and the summary record that context was sent" "true 1" \
  "$(jq -r '"\(.findings[0].decisions.code_context) \(.decisions_summary.context.findings_with_code_context)"' "$TMP_DIR/ctx.json")"
printf '{"changed_functions":[{"name":"t_thing","file_path":"%s/src/a.sh","line_start":18,"line_end":22,"is_test":true}]}\n' "$SB" > "$TMP_DIR/graph_norisk.json"
reset_stub ctx_norisk
merged_doc "$TMP_DIR/ctx_nr.json" "$F1"
(cd "$SB" && _DECISIONS_SOURCE_REV="$HEAD_SHA" _DECISIONS_GRAPH_JSON="$TMP_DIR/graph_norisk.json" scorer "$TMP_DIR/ctx_nr.json" >/dev/null 2>&1)
check "Test 2a2: a graph entry without risk_score keeps its fields in place (tab is IFS whitespace)" "1" \
  "$(ctx_of "gate alpha" | grep -c 'Enclosing function `t_thing` (lines 18-22 of `src/a.sh`, a test), as of')"
reset_stub ctx_window
merged_doc "$TMP_DIR/ctx_w.json" "$F1"
(cd "$SB" && _DECISIONS_SOURCE_REV="$HEAD_SHA" scorer "$TMP_DIR/ctx_w.json" >/dev/null 2>&1)
check "Test 2e: without the graph a line window is used" "1" \
  "$(ctx_of "gate alpha" | grep -c 'Lines 1-50 of `src/a.sh` around the finding')"
reset_stub ctx_off
merged_doc "$TMP_DIR/ctx_off.json" "$F1"
(cd "$SB" && OPENCODE_REVIEW_REPORT_DECISIONS_CODE_CONTEXT=0 _DECISIONS_SOURCE_REV="$HEAD_SHA" scorer "$TMP_DIR/ctx_off.json" >/dev/null 2>&1)
check "Test 2f: CODE_CONTEXT=0 sends no code context and records none" "<none> false none" \
  "$(ctx_of "gate alpha") $(jq -r '"\(.findings[0].decisions.code_context) \(.decisions_summary.context.findings_with_code_context // "none")"' "$TMP_DIR/ctx_off.json")"
reset_stub ctx_badrev
merged_doc "$TMP_DIR/ctx_br.json" "$F1"
(cd "$SB" && _DECISIONS_SOURCE_REV=0123456789abcdef0123456789abcdef01234567 scorer "$TMP_DIR/ctx_br.json" > "$TMP_DIR/ctx_br.log" 2>&1)
ctx="$(ctx_of "gate alpha")"
check "Test 2g: an unknown revision is said, and only the named-file hunk is sent" "1|0|1" \
  "$(grep -c "revision '0123456789abcdef0123456789abcdef01234567' is not available here" "$TMP_DIR/ctx_br.log")|$(printf '%s\n' "$ctx" | grep -c 'Lines ')|$(printf '%s\n' "$ctx" | grep -c 'Hunk of `src/b.sh`')"
reset_stub ctx_nothing
merged_doc "$TMP_DIR/ctx_n.json" "$F2"
(cd "$SB" && scorer "$TMP_DIR/ctx_n.json" >/dev/null 2>&1)
check "Test 2h: no revision and no named file → no code_context key at all" "<none>" "$(ctx_of "badfs gate")"

# Budget order: context gives way before the hunk is trimmed. The fixtures are
# sized against the scorer's budget (40,000 bytes): ~22 KB of hunk plus 10 KB of
# rules fits on its own, and does not with a full code context.
make_big() { # make_big <dir> <lines> <diff_out>
  mkdir -p "$1/src"
  (
    cd "$1"
    git init -q && git config user.email t@t && git config user.name t
    : > src/c.sh
    git add -A && git commit -qm base
    for i in $(seq 1 "$2"); do printf 'added line %03d %s\n' "$i" "$(printf 'x%.0s' $(seq 1 150))"; done > src/c.sh
    git add -A && git commit -qm head
    git diff HEAD~1..HEAD > "$3"
  )
}
BIG="$TMP_DIR/big"
make_big "$BIG" 130 "$TMP_DIR/big_diff.txt"
head -c 10000 /dev/zero | tr '\0' 'r' > "$TMP_DIR/big_rules.md"
merged_doc "$TMP_DIR/big.json" '{"#":1,"title":"big","severity":"medium","file":"src/c.sh","line":45,"why_it_matters":"w","verified":true,"chunks":[0]}'
reset_stub big
(cd "$BIG" && env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
  _DECISIONS_RETRY_DELAY=0 _DECISIONS_SOURCE_REV="$(git rev-parse HEAD)" \
  bash "$SCORER" "$TMP_DIR/big.json" "$TMP_DIR/no_reviews" 1 "$TMP_DIR/big_diff.txt" "$TMP_DIR/big_rules.md" > "$TMP_DIR/big.log" 2>&1)
check "Test 2i: over budget, the context is rebuilt narrower but still centred on the finding — and the hunk is untouched" "1|1|1|0" \
  "$(grep -c 'code context shortened to fit' "$TMP_DIR/big.log")|$(ctx_of big | grep -cE 'Lines (3[0-9]|4[0-5])-(4[5-9]|5[0-9]) of `src/c.sh` around the finding')|$(ctx_of big | grep -c '^    45 | added line 045')|$(grep -c 'diff hunk truncated' "$TMP_DIR/big.log" || true)"
check "Test 2j: …and the finding request fits the budget" "yes" \
  "$(s="$(finding_reqs | head -n 1 | wc -c | tr -d ' ')"; [ "$s" -le 40000 ] && echo yes || echo "no ($s)")"
# A long enclosing function from the graph: narrowed around the line, label kept.
printf '{"changed_functions":[{"name":"huge","file_path":"%s/src/c.sh","line_start":1,"line_end":130,"risk_score":0.5}]}\n' "$BIG" > "$TMP_DIR/graph_big.json"
reset_stub big_fn
merged_doc "$TMP_DIR/big_fn.json" '{"#":1,"title":"big","severity":"medium","file":"src/c.sh","line":60,"why_it_matters":"w","verified":true,"chunks":[0]}'
(cd "$BIG" && env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
  _DECISIONS_RETRY_DELAY=0 _DECISIONS_SOURCE_REV="$(git rev-parse HEAD)" _DECISIONS_GRAPH_JSON="$TMP_DIR/graph_big.json" \
  bash "$SCORER" "$TMP_DIR/big_fn.json" "$TMP_DIR/no_reviews" 1 "$TMP_DIR/big_diff.txt" > /dev/null 2>&1)
check "Test 2k: a function too long for the source budget keeps its name and shows the lines around the finding" "1|1|0" \
  "$(ctx_of big | grep -c 'Enclosing function `huge` (lines 1-130 of `src/c.sh`, code-graph risk 0.5), lines 50-70 around the finding')|$(ctx_of big | grep -c '^    60 | ')|$(ctx_of big | grep -c '^     1 | ')"
# No room at all (rules at their cap): the context is dropped, THEN the hunk trimmed.
head -c 13000 /dev/zero | tr '\0' 'r' > "$TMP_DIR/cap_rules.md"
BIG2="$TMP_DIR/big2"
make_big "$BIG2" 200 "$TMP_DIR/big2_diff.txt"
reset_stub big_drop
merged_doc "$TMP_DIR/big_d.json" '{"#":1,"title":"big","severity":"medium","file":"src/c.sh","line":45,"why_it_matters":"w","verified":true,"chunks":[0]}'
(cd "$BIG2" && env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
  _DECISIONS_RETRY_DELAY=0 _DECISIONS_SOURCE_REV="$(git rev-parse HEAD)" \
  bash "$SCORER" "$TMP_DIR/big_d.json" "$TMP_DIR/no_reviews" 1 "$TMP_DIR/big2_diff.txt" "$TMP_DIR/cap_rules.md" > "$TMP_DIR/big_d.log" 2>&1)
check "Test 2l: no room → context dropped before the hunk is trimmed, in that order" "dropped,truncated|<none>|false" \
  "$(grep -oE 'code context dropped|diff hunk truncated' "$TMP_DIR/big_d.log" | sed 's/code context //; s/diff hunk //' | paste -sd, -)|$(ctx_of big)|$(jq -r '.findings[0].decisions.code_context' "$TMP_DIR/big_d.json")"
# Secret-looking paths never reach the vendor as code context.
SEC="$TMP_DIR/sec"
mkdir -p "$SEC/config"
(
  cd "$SEC"
  git init -q && git config user.email t@t && git config user.name t
  printf 'A=1\n' > .env.production; printf 'k\n' > config/server.pem; printf 'x\n' > app.sh
  git add -A && git commit -qm base
  printf 'A=2\nTOKEN=s3cr3t\n' > .env.production; printf 'k2\n' > config/server.pem; printf 'y\n' > app.sh
  git commit -qam head
  git diff HEAD~1..HEAD > "$TMP_DIR/sec_diff.txt"
)
merged_doc "$TMP_DIR/sec.json" '{"#":1,"title":"env","severity":"medium","file":".env.production","line":2,"why_it_matters":"see config/server.pem and app.sh","verified":true}'
reset_stub sec
(cd "$SEC" && env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
  _DECISIONS_RETRY_DELAY=0 _DECISIONS_SOURCE_REV="$(git rev-parse HEAD)" \
  bash "$SCORER" "$TMP_DIR/sec.json" "$TMP_DIR/no_reviews" 1 "$TMP_DIR/sec_diff.txt" > "$TMP_DIR/sec.log" 2>&1)
ctx="$(ctx_of env)"
check "Test 2m: a secret-looking file gets no source excerpt and no named-file hunk; an ordinary one still does" "0|0|1" \
  "$(printf '%s\n' "$ctx" | grep -c '\.env\.production` around')|$(printf '%s\n' "$ctx" | grep -c 'server.pem')|$(printf '%s\n' "$ctx" | grep -c 'Hunk of `app.sh`')"
check "Test 2n: a path named with a slash is looked up without a stray-backslash grep warning" "0" \
  "$(grep -c 'stray' "$TMP_DIR/sec.log" || true)"
# End to end for secret-NAMED paths (review 5331393801 finding 2): a finding in
# secrets/production.json that names config/secrets.yml gets neither a source
# excerpt nor a named-file hunk; the ordinary file it names still does.
SEC2="$TMP_DIR/sec2"
mkdir -p "$SEC2/secrets" "$SEC2/config"
(
  cd "$SEC2"
  git init -q && git config user.email t@t && git config user.name t
  printf '{"db":"a"}\n' > secrets/production.json; printf 'k: a\n' > config/secrets.yml; printf 'x\n' > app.sh
  git add -A && git commit -qm base
  printf '{"db":"b","token":"s3cr3t"}\n' > secrets/production.json; printf 'k: b\n' > config/secrets.yml; printf 'y\n' > app.sh
  git commit -qam head
  git diff HEAD~1..HEAD > "$TMP_DIR/sec2_diff.txt"
)
merged_doc "$TMP_DIR/sec2.json" '{"#":1,"title":"sec2","severity":"medium","file":"secrets/production.json","line":1,"why_it_matters":"see config/secrets.yml and app.sh","verified":true}'
reset_stub sec2
(cd "$SEC2" && env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
  _DECISIONS_RETRY_DELAY=0 _DECISIONS_SOURCE_REV="$(git rev-parse HEAD)" \
  bash "$SCORER" "$TMP_DIR/sec2.json" "$TMP_DIR/no_reviews" 1 "$TMP_DIR/sec2_diff.txt" > "$TMP_DIR/sec2.log" 2>&1)
ctx="$(ctx_of sec2)"
check "Test 2p: secret-named paths get no source excerpt and no named-file hunk; an ordinary one still does" "0|0|0|1" \
  "$(printf '%s\n' "$ctx" | grep -c 'production.json` around')|$(printf '%s\n' "$ctx" | grep -c 's3cr3t')|$(printf '%s\n' "$ctx" | grep -c 'Hunk of `config/secrets.yml`')|$(printf '%s\n' "$ctx" | grep -c 'Hunk of `app.sh`')"
# Review 5331424628 finding 1: a finding on a tracked .kube/config that names a
# kubeconfig file gets neither an excerpt nor a named-file hunk.
KUBE="$TMP_DIR/kube"
mkdir -p "$KUBE/.kube" "$KUBE/ops"
(
  cd "$KUBE"
  git init -q && git config user.email t@t && git config user.name t
  printf 'token: a\n' > .kube/config; printf 'token: a\n' > ops/prod.kubeconfig; printf 'x\n' > app.sh
  git add -A && git commit -qm base
  printf 'token: kub3s3cr3t\n' > .kube/config; printf 'token: b\n' > ops/prod.kubeconfig; printf 'y\n' > app.sh
  git commit -qam head
  git diff HEAD~1..HEAD > "$TMP_DIR/kube_diff.txt"
)
merged_doc "$TMP_DIR/kube.json" '{"#":1,"title":"kube","severity":"medium","file":".kube/config","line":1,"why_it_matters":"see ops/prod.kubeconfig and app.sh","verified":true}'
reset_stub kube
(cd "$KUBE" && env PATH="$BIN:$PATH" OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_GO_OPENAI_API_KEY=k \
  _DECISIONS_RETRY_DELAY=0 _DECISIONS_SOURCE_REV="$(git rev-parse HEAD)" \
  bash "$SCORER" "$TMP_DIR/kube.json" "$TMP_DIR/no_reviews" 1 "$TMP_DIR/kube_diff.txt" > "$TMP_DIR/kube.log" 2>&1)
ctx="$(ctx_of kube)"
check "Test 2q: .kube/config and a named kubeconfig get no excerpt and no hunk; an ordinary file still does" "0|0|1" \
  "$(printf '%s\n' "$ctx" | grep -c '\.kube/config` around')|$(printf '%s\n' "$ctx" | grep -c 'Hunk of `ops/prod.kubeconfig`')|$(printf '%s\n' "$ctx" | grep -c 'Hunk of `app.sh`')"
# The path check itself: directory components and Terraform JSON vars count too.
eval "$(awk '/^is_sensitive_path\(\) \{/,/^\}/' "$SCORER")"
sens=""
for p in .env config/.env.local/db.yml .env/settings.json deploy/.ssh/config home/.aws/credentials .gnupg/pubring.kbx \
         infra/prod.tfvars.json infra/x.auto.tfvars.json infra/state.tfstate.backup \
         secrets/production.json config/secrets.yml .secrets/token deploy/app-secrets.yaml k8s/db-secret.yaml .envrc \
         .kube/config deploy/.kube/prod.yaml ops/kubeconfig ops/prod.kubeconfig .azure/accessTokens.json \
         .config/gcloud/credentials.db .docker/config.json; do
  is_sensitive_path "$p" && sens="${sens}y" || sens="${sens}n"
done
for p in src/env.sh docs/environment.md src/.envrc_notes/readme.md infra/main.tf app/ssh/client.go \
         docs/secrets-management.md src/secretary.py \
         .docker/Dockerfile docs/kubernetes.md src/kube/client.go; do
  is_sensitive_path "$p" && sens="${sens}y" || sens="${sens}n"
done
check "Test 2o: sensitive directories, secret-named files, cluster/cloud credentials and *.tfvars.json are excluded; look-alikes are not" "yyyyyyyyyyyyyyyyyyyyyynnnnnnnnnn" "$sens"


# --- 3. findings_with_rules counts only requests actually sent -------------------------
echo ""
echo "--- rules count ---"
HUGE="$(head -c 45000 /dev/zero | tr '\0' 'w')"
merged_doc "$TMP_DIR/cnt.json" "$F1" "{\"#\":2,\"title\":\"huge\",\"severity\":\"low\",\"file\":\"src/a.sh\",\"line\":3,\"why_it_matters\":\"$HUGE\",\"verified\":true}"
printf 'Rule: be nice.\n' > "$TMP_DIR/rules.md"
reset_stub cnt
(cd "$SB" && scorer "$TMP_DIR/cnt.json" "$TMP_DIR/rules.md" > "$TMP_DIR/cnt.log" 2>&1)
check "Test 3a: an over-budget finding is skipped and not counted as having been sent rules" "1|1" \
  "$(grep -c 'finding 2: request is .* bytes even without its diff hunk — skipped' "$TMP_DIR/cnt.log")|$(jq -r '.decisions_summary.context.findings_with_rules' "$TMP_DIR/cnt.json")"

# --- 4. review-diff.sh ----------------------------------------------------------------
echo ""
echo "--- the diff as reviewed ---"
printf 'CURRENT DIFF\n' > "$TMP_DIR/current.diff"
printf 'REVIEWED DIFF\n' > "$TMP_DIR/reviewed.diff"
printf '## 🤖 OpenCode CLI Code Review - Commit: `abc1234`\n\nbody\n' > "$TMP_DIR/hdr.md"
rd() { # rd <case> [env...] -- <args> → "state|second line|out contents"
  local name="$1"; shift
  reset_stub "rd_$name"
  local out="$TMP_DIR/rd_$name.diff" res
  res="$(env PATH="$BIN:$PATH" GH_CURRENT_DIFF="$TMP_DIR/current.diff" GH_REVIEWED_DIFF="$TMP_DIR/reviewed.diff" "$@" \
    bash "$REVIEW_DIFF" 7 "$TMP_DIR/hdr.md" "$out" ${KNOWN:-})"
  printf '%s|%s|%s' "$(printf '%s\n' "$res" | sed -n 1p)" "$(printf '%s\n' "$res" | sed -n 2p)" "$(cat "$out")"
}
check "Test 4a: the review header names the PR head → current diff" "current|abc1234ffffffffffffffffffffffffffffffffff|CURRENT DIFF" \
  "$(rd same GH_HEAD=abc1234ffffffffffffffffffffffffffffffffff)"
check "Test 4b: the PR moved on → the diff at the reviewed commit, via the compare API" \
  "reviewed|abc1234000000000000000000000000000000000|REVIEWED DIFF" \
  "$(rd moved GH_HEAD=fffffff000000000000000000000000000000000 GH_FULL_SHA=abc1234000000000000000000000000000000000)"
check "Test 4c: …comparing the base branch with the FULL reviewed sha (three-dot)" "1" \
  "$(grep -c 'compare/main\.\.\.abc1234000000000000000000000000000000000' "$TMP_DIR/stub_rd_moved/compare.log")"
check "Test 4d: moved on and the compare fails → unavailable with an EMPTY diff, never the current one" \
  "unavailable|abc1234000000000000000000000000000000000|" \
  "$(rd fail GH_HEAD=fffffff000000000000000000000000000000000 GH_FULL_SHA=abc1234000000000000000000000000000000000 GH_COMPARE_FAIL=1)"
check "Test 4e: a known sha (artifact metadata) is preferred over the header" "current|dddddddddddddddddddddddddddddddddddddddd|CURRENT DIFF" \
  "$(KNOWN=dddddddddddddddddddddddddddddddddddddddd rd known GH_HEAD=dddddddddddddddddddddddddddddddddddddddd)"
printf 'no header here\n' > "$TMP_DIR/hdr.md"
check "Test 4f: no reviewed commit → unknown, current diff" "unknown||CURRENT DIFF" "$(rd nohdr GH_HEAD=fffffff000000000000000000000000000000000)"
printf '## 🤖 OpenCode CLI Code Review - Commit: `abc1234`\n\nbody\n' > "$TMP_DIR/hdr.md"
check "Test 4f2: a known reviewed commit but an unreadable PR head → unavailable with an EMPTY diff, never the current one" \
  "unavailable|abc1234|" "$(rd nohead GH_HEAD=)"
set +e
bash "$REVIEW_DIFF" x y z >/dev/null 2>&1; rc_u=$?
set -e
check "Test 4g: a non-numeric PR is a usage error" "64" "$rc_u"

# --- 5. reuse of the gate's answers ------------------------------------------------------
echo ""
echo "--- reuse before re-asking ---"
BODY="$TMP_DIR/body.md"
cat > "$BODY" <<'EOF'
## 🤖 OpenCode CLI Code Review - Commit: `abc1234`

## 🔍 Issues Summary

### 🟡 Medium Priority Issues

1. 🟡 [VERIFIED] Medium Priority: gate alpha — `src/a.sh:20` (chunk 0)
2. 🟡 [VERIFIED] Medium Priority: skipme gate beta — `src/a.sh:21` (chunk 0)
3. 🟡 [VERIFIED] Medium Priority: fresh gamma — `src/a.sh:22` (chunk 0)

### 📊 Coverage

<!-- ai-review-report run-id=777 -->
EOF
ART="$TMP_DIR/artifact"
mkdir -p "$ART/rules/chunk_0"
gd() { # gd <choice> <p_fix> → a gate decisions object
  printf '{"provider":"OPENCODE-GO-DECISIONS","model":"jev-1.13","supported":0.9,"severity":{"choice":"medium"},"pre_existing":0.1,"sanctioned":0.05,"previously_skipped":0.1,"diff_hunk_found":true,"actionability":{"score":1.8},"fix_skip":{"choice":"%s","probabilities":{"fix":%s},"skip_probability":%s}}' \
    "$1" "$2" "$(awk -v p="$2" 'BEGIN { printf "%g", 1 - p }')"
}
jq -n --argjson d1 "$(gd fix 0.9)" --argjson d2 "$(gd skip_invalid 0.2)" '{status:"complete", findings:[
  {"#":1, file:"src/a.sh", title:"gate alpha", first_evidence:"src/a.sh:20 -- line 20", chunks:[0], decisions:$d1},
  {"#":2, file:"src/a.sh", title:"skipme gate beta", first_evidence:"src/a.sh:21 -- line 21", chunks:[0], decisions:$d2},
  {"#":3, file:"src/a.sh", title:"fresh gamma", first_evidence:"src/a.sh:22 -- line 22", chunks:[0]}]}' > "$ART/findings.merged.json"
printf -- '- **9.** old — **skip reason:** x\n' > "$ART/decision_skip_areas.md"
printf 'Project rule: gamma is fine.\n' > "$ART/rules/chunk_0/AGENTS.md"
printf '{"head_sha":"%s","base_sha":"%s"}\n' "$HEAD_SHA" "$(git -C "$SB" rev-parse HEAD~1)" > "$ART/metadata.json"
printf -- '- **9.** old — **skip reason:** x\n' > "$TMP_DIR/skips_same.md"
printf -- '- **9.**   old —\n  **skip reason:** x\n' > "$TMP_DIR/skips_rewrapped.md"
printf -- '- **2.** new — **skip reason:** y\n' > "$TMP_DIR/skips_new.md"
rec() { # rec <case> <skips> [env...] — run from the sandbox so --rev resolves
  local name="$1" skips="$2"; shift 2
  reset_stub "rec_$name"
  (cd "$SB" && env PATH="$BIN:$PATH" OPENCODE_GO_OPENAI_API_KEY=k OPENCODE_OPENROUTER_API_KEY=k _DECISIONS_RETRY_DELAY=0 "$@" \
    bash "$RECOMMEND" --scope review --review "$BODY" --out-dir "$TMP_DIR/out_$name" \
      --diff "$DIFF" --skip-areas "$skips" --artifact "$ART/findings.merged.json" --rev "$HEAD_SHA" > "$TMP_DIR/rec_$name.log" 2>&1)
}
rec reuse "$TMP_DIR/skips_same.md"
check "Test 5a: only the finding the gate did not answer is re-asked (preflight + 1)" "2|fresh gamma" \
  "$(calls)|$(finding_reqs | jq -r '.state.finding.title')"
check "Test 5b: the source column says which answer is whose" "1 gate|2 gate|3 rescored" \
  "$(awk -F '\t' 'NR > 1 { printf "%s%s %s", s, $1, $16; s = "|" }' "$TMP_DIR/out_reuse/recommendations.tsv")"
check "Test 5c: the gate answers are used as given (finding 2 SKIP invalid at P(skip) 80%)" "SKIP invalid 80" \
  "$(awk -F '\t' '$1 == 2 { print $3, $4, $5 }' "$TMP_DIR/out_reuse/recommendations.tsv")"
check "Test 5d: the re-score gets the artifact's per-chunk rules and the code at the reviewed commit" "1|1" \
  "$(finding_reqs | jq -r '.state.project_rules // ""' | grep -c 'gamma is fine')|$(finding_reqs | jq -r '.state.code_context // ""' | grep -c '^    22 | line 22 of a$')"
check "Test 5e: the table carries the Source column and no # + digit" "1|0" \
  "$(grep -c '| Source |' "$TMP_DIR/out_reuse/recommendations.md")|$(grep -cE '#[0-9]' "$TMP_DIR/out_reuse/recommendations.md" || true)"
check "Test 5f: the reuse is announced" "1" "$(grep -c '2 of 3 finding(s) reuse the gate' "$TMP_DIR/rec_reuse.log")"
rec rescore_down "$TMP_DIR/skips_same.md" STUB_FAIL=1
check "Test 5f2: gate answers still render when the re-score fails, and the header says what is missing" "scored|2|1" \
  "$(cat "$TMP_DIR/out_rescore_down/status")|$(grep -c '| gate |$' "$TMP_DIR/out_rescore_down/recommendations.md")|$(grep -c '2 from the gate.s own scoring, 0 re-scored, 1 not scored — no row' "$TMP_DIR/out_rescore_down/recommendations.md")"
rec rewrap "$TMP_DIR/skips_rewrapped.md"
check "Test 5g: re-wrapped Skip Areas are the same decision — still reused" "2" "$(calls)"
rec changed "$TMP_DIR/skips_new.md"
check "Test 5h: new Skip Areas → every finding is re-scored, and it says why" "4|1" \
  "$(calls)|$(grep -c "Skip Areas changed since the gate scored" "$TMP_DIR/rec_changed.log")"
rec provider "$TMP_DIR/skips_same.md" OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER=OPENROUTER-DECISIONS
check "Test 5i: another decision provider → re-scored" "4|1" \
  "$(calls)|$(grep -c 'the gate used OPENCODE-GO-DECISIONS, this scope asks for OPENROUTER-DECISIONS' "$TMP_DIR/rec_provider.log")"
rec model "$TMP_DIR/skips_same.md" OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.14
check "Test 5j: another model → re-scored" "4" "$(calls)"
# The gate records the model the provider RETURNED (a dated snapshot) next to
# the one it REQUESTED. Reuse compares requested with configured — comparing the
# returned name never matched, so no gate answer was ever reused (PR 179 run
# 36338648038: "the gate used model typesafe/jev-1.13-20260917, this scope asks
# for typesafe/jev-1.13").
cp "$ART/findings.merged.json" "$TMP_DIR/art_saved.json"
jq '.findings |= map(if .decisions then .decisions += {model: "jev-1.13-20260917", requested_model: "jev-1.13"} else . end)' \
  "$TMP_DIR/art_saved.json" > "$ART/findings.merged.json"
rec snapshot "$TMP_DIR/skips_same.md" OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13
check "Test 5j2: a dated returned snapshot of the configured model is reused (requested id recorded)" "2|0" \
  "$(calls)|$(grep -c 'gate answers not reused' "$TMP_DIR/rec_snapshot.log" || true)"
jq '.findings |= map(if .decisions then .decisions += {model: "jev-1.13-20260917"} | del(.decisions.requested_model) else . end)' \
  "$TMP_DIR/art_saved.json" > "$ART/findings.merged.json"
rec legacy "$TMP_DIR/skips_same.md" OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13
check "Test 5j3: an older artifact with only the dated name is reused too" "2" "$(calls)"
jq '.findings |= map(if .decisions then .decisions += {model: "jev-1.13-beta"} | del(.decisions.requested_model) else . end)' \
  "$TMP_DIR/art_saved.json" > "$ART/findings.merged.json"
rec notdate "$TMP_DIR/skips_same.md" OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13
check "Test 5j4: a non-date suffix is another model → re-scored" "4" "$(calls)"
jq '.findings |= map(if .decisions then .decisions += {model: "jev-1.13-20260917", requested_model: "jev-1.12"} else . end)' \
  "$TMP_DIR/art_saved.json" > "$ART/findings.merged.json"
rec otherreq "$TMP_DIR/skips_same.md" OPENCODE_REVIEW_REPORT_DECISIONS_MODEL=jev-1.13
check "Test 5j5: the gate requested another model → re-scored, and the note names what it requested" "4|1" \
  "$(calls)|$(grep -c 'the gate used model jev-1.12, this scope asks for jev-1.13' "$TMP_DIR/rec_otherreq.log")"
cp "$TMP_DIR/art_saved.json" "$ART/findings.merged.json"
mv "$ART/decision_skip_areas.md" "$TMP_DIR/saved_skips.md"
rec noskipfile "$TMP_DIR/skips_same.md"
mv "$TMP_DIR/saved_skips.md" "$ART/decision_skip_areas.md"
check "Test 5k: an artifact that does not record its Skip Areas cannot prove reuse is valid → re-scored" "4|1" \
  "$(calls)|$(grep -c 'does not record the Skip Areas' "$TMP_DIR/rec_noskipfile.log")"
jq '.findings[2].decisions = .findings[0].decisions' "$ART/findings.merged.json" > "$TMP_DIR/all.json" && cp "$TMP_DIR/all.json" "$ART/findings.merged.json"
rec allgate "$TMP_DIR/skips_same.md"
check "Test 5l: every finding answered by the gate → no request at all, and still a table" "0|scored|3" \
  "$(calls)|$(cat "$TMP_DIR/out_allgate/status")|$(grep -c '| gate |' "$TMP_DIR/out_allgate/recommendations.md")"
check "Test 5m: the summary names the gate provider when nothing was re-scored" "OPENCODE-GO-DECISIONS/jev-1.13 3" \
  "$(jq -r '.decisions_summary | "\(.provider)/\(.model) \(.reused)"' "$TMP_DIR/out_allgate/decisions.json")"
out="$(awk '/^### 🟡 Medium/{f=1; next} /^### /{f=0} f' "$BODY" | bash "$APPLY" "$TMP_DIR/out_allgate/recommendations.tsv" "" "$TMP_DIR/rep_gate")"
check "Test 5n: ai-analyse's advisory line says when the answer is the gate's" "3" \
  "$(printf '%s\n' "$out" | grep -c '(advisory, from gate scoring)$')"

# --- 6. /ai-review --usedecisions end to end ---------------------------------------------
echo ""
echo "--- review-decisions.sh ---"
rdx() { # rdx <case> [env...]
  local name="$1"; shift
  reset_stub "rdx_$name"
  (cd "$SB" && env PATH="$BIN:$PATH" GH_BODY="$BODY" GH_CURRENT_DIFF="$DIFF" GH_REVIEWED_DIFF="$DIFF" \
    GH_ARTIFACT_DIR="$ART" OPENCODE_GO_OPENAI_API_KEY=k _DECISIONS_RETRY_DELAY=0 "$@" \
    bash "$REVIEW_DECISIONS" 7 > "$TMP_DIR/rdx_$name.log" 2>&1)
}
jq '.findings[2] |= del(.decisions)' "$ART/findings.merged.json" > "$TMP_DIR/two.json" && cp "$TMP_DIR/two.json" "$ART/findings.merged.json"
printf '## Skip Areas / Known Issues\n\n- **9.** old — **skip reason:** x\n\n## AI Review Notes\n' > "$TMP_DIR/pr_body.md"
rdx current GH_HEAD="$HEAD_SHA" GH_PR_BODY="$TMP_DIR/pr_body.md"
check "Test 6a: the always-on run-id marker finds the artifact" "1" "$(grep -c 'run download 777 -n review-run-777' "$STUB_DIR/gh.log")"
check "Test 6b: the head matches the artifact → no revision note, gate answers reused" "0|1" \
  "$(grep -c 'moved on' "$TMP_DIR/rdx_current.log" || true)|$(grep -c '| 1\. | 🟡 Medium | `src/a.sh:20` | FIX | 10% |.* gate |$' "$TMP_DIR/rdx_current.log")"
rdx moved GH_HEAD=fffffff000000000000000000000000000000000 GH_FULL_SHA="$HEAD_SHA"
check "Test 6c: the PR moved on → judged at the reviewed commit, and said" "1|1" \
  "$(grep -c "judged against the reviewed commit ${HEAD_SHA:0:7}" "$TMP_DIR/rdx_moved.log")|$(grep -c "compare/main...${HEAD_SHA}" "$STUB_DIR/compare.log")"
rdx unavailable GH_HEAD=fffffff000000000000000000000000000000000 GH_FULL_SHA="$HEAD_SHA" GH_COMPARE_FAIL=1
check "Test 6d: the reviewed diff cannot be fetched → no recommendations, no request, exit 0" "1|0|0" \
  "$(grep -c 'no decision-model recommendations (judging the current code would score lines the review never saw)' "$TMP_DIR/rdx_unavailable.log")|$(calls)|$(grep -c '^| ' "$TMP_DIR/rdx_unavailable.log" || true)"

# An older ai-review-report next to a newer ai-review (separate plugins).
OLD_REPORT="$TMP_DIR/old_report"
mkdir -p "$OLD_REPORT"
cp -R "$SCRIPT_DIR/.." "$OLD_REPORT/ai-review-report"
rm -f "$OLD_REPORT/ai-review-report/scripts/lib/review-diff.sh"
rdx oldreport GH_HEAD=fffffff000000000000000000000000000000000 GH_PR_BODY="$TMP_DIR/pr_body.md" AI_REVIEW_REPORT_DIR="$OLD_REPORT/ai-review-report"
check "Test 6e: an ai-review-report without review-diff.sh → current diff, said, recommendations still given (never a false 'moved on')" "1|0|1" \
  "$(grep -c 'predates review-diff.sh' "$TMP_DIR/rdx_oldreport.log")|$(grep -c 'moved on' "$TMP_DIR/rdx_oldreport.log" || true)|$(grep -c '^| 1\. ' "$TMP_DIR/rdx_oldreport.log")"

# --- 7. the gate's run artifact and marker --------------------------------------------------
echo ""
echo "--- run artifact and marker ---"
W="$TMP_DIR/w"
mkdir -p "$W/ci_temp/chunk_0" "$W/ci_temp/chunk_2" "$W/ci_temp/chunk_3"
printf 'rules zero\n' > "$W/ci_temp/chunk_0/AGENTS.md"
printf 'rules two\n' > "$W/ci_temp/chunk_2/AGENTS.md"
: > "$W/ci_temp/chunk_3/AGENTS.md"
printf -- '- skip\n' > "$W/ci_temp/decision_skip_areas.md"
# Up to the trap that registers it: the function's metadata heredoc holds a
# bare `}` line, so a `/^}/` range would stop inside it.
awk '/^assemble_run_artifacts\(\) \{/{f=1} /^trap .*assemble_run_artifacts/{exit} f' "$RUN_REVIEW" > "$W/fn.sh"
(cd "$W" && WORK_DIR=ci_temp GITHUB_OUTPUT=/dev/null bash -c '. ./fn.sh; assemble_run_artifacts' >/dev/null 2>&1)
check "Test 7a: the run artifact carries the judge's Skip Areas and every non-empty chunk rules file" \
  "- skip|rules zero|rules two|absent" \
  "$(cat "$W/ci_temp/run/decision_skip_areas.md")|$(cat "$W/ci_temp/run/rules/chunk_0/AGENTS.md")|$(cat "$W/ci_temp/run/rules/chunk_2/AGENTS.md")|$([ -e "$W/ci_temp/run/rules/chunk_3" ] && echo present || echo absent)"
marker() { # marker <artifacts flag> <run id> [assembled] → what the block appends
  local d="$TMP_DIR/mk_$RANDOM"
  mkdir -p "$d/ci_temp"; : > "$d/ci_temp/final_review.md"
  awk '/^# LADR-098 run-id channel/{f=1} f{print} f && /^fi$/{exit}' "$AGG_SH" > "$d/block.sh"
  (cd "$d" && OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS="$1" GITHUB_RUN_ID="$2" _REVIEW_RUN_ARTIFACT="${3:-1}" bash block.sh >/dev/null 2>&1)
  tr -d '\n' < "$d/ci_temp/final_review.md"
}
check "Test 7b: the run-id marker is written whenever an artifact is uploaded, scored or not" "<!-- ai-review-report run-id=4242 -->" \
  "$(marker 1 4242)"
check "Test 7c: …and never with artifacts off, a non-numeric id, or outside run-review.sh (npm-in-CI via local-review.sh)" "||" \
  "$(marker 0 4242)|$(marker 1 'x -->')|$(marker 1 4242 0)"
check "Test 7c2: run-review.sh announces that it assembles the artifact; local-review.sh does not" "1|0" \
  "$(grep -c '^export _REVIEW_RUN_ARTIFACT=1$' "$RUN_REVIEW")|$(grep -c '_REVIEW_RUN_ARTIFACT' "$LOCAL_REVIEW" || true)"
check "Test 7d: the run-id marker cannot be mistaken for the label marker ai-review execute keys on" "0" \
  "$(printf '<!-- ai-review-report run-id=4242 -->\n' | grep -c '<!-- ai-review-report run=[0-9]' || true)"
check "Test 7e: run-review.sh asks fix_skip and passes the reviewed revision and the graph to the scorer" "3" \
  "$(awk '/Step 17.6/{f=1} f && /_DECISIONS_ASK_FIX_SKIP=1|_DECISIONS_SOURCE_REV="\$\{head_sha\}"|_DECISIONS_GRAPH_JSON="\$WORK_DIR\/graph_detect_changes.json"/{n++} f && /score-findings-decisions\.sh" \\$/{print n; exit}' "$RUN_REVIEW")"
check "Test 7f: local-review.sh asks fix_skip and passes the reviewed revision" "2" \
  "$(awk '/Step 5c/{f=1} f && /_DECISIONS_ASK_FIX_SKIP=1|_DECISIONS_SOURCE_REV="\$\{TO_SHA\}"/{n++} f && /score-findings-decisions\.sh" \\$/{print n; exit}' "$LOCAL_REVIEW")"
check "Test 7g: the npm example forwards the code-context Variable" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_DECISIONS_CODE_CONTEXT: \${{ vars.OPENCODE_REVIEW_REPORT_DECISIONS_CODE_CONTEXT }}' "$REPO_ROOT/.docs/examples/npm-review-report-gha.yml")"

# --- 8. the eval records and reports fix_skip --------------------------------------------
echo ""
echo "--- eval ---"
# shellcheck disable=SC1090
. "$RECORD_SH"
printf '{"id":"MC-X","kind":"must-catch","min_severity":"MEDIUM"}\n' > "$TMP_DIR/mc.json"
printf '{"id":"DR-X","kind":"must-not-flag","forbidden_claim":"wrong"}\n' > "$TMP_DIR/dr.json"
mkdir -p "$TMP_DIR/records"
jq '.decisions_summary = {provider:"P", model:"M", scored:3}' "$TMP_DIR/gate.json" > "$TMP_DIR/rec_mc.json"
jq '.findings[0].verified = true' "$TMP_DIR/rec_mc.json" > "$TMP_DIR/rec_mc2.json"
write_decision_record "$TMP_DIR/rec_mc2.json" "$TMP_DIR/mc.json" 1 "" "" /dev/null "$TMP_DIR/records/MC-X.1.json" 2>/dev/null || true
check "Test 8a: a measurement record carries fix_skip, its P(skip) and code_context" "fix 0.25" \
  "$(jq -r '.findings[0] | "\(.fix_skip) \(.fix_skip_p)"' "$TMP_DIR/records/MC-X.1.json")"
jq -n '{status:"complete", merged_chunks:[0], decisions_summary:{provider:"P", model:"M", scored:1},
  findings:[{"#":1, severity:"high", verified:true, title:"wrong claim", why_it_matters:"wrong",
    decisions:{supported:0.3, severity:{choice:"high"}, pre_existing:0.1, actionability:{score:1},
               diff_hunk_found:true, fix_skip:{choice:"skip_invalid", skip_probability:0.85}}}]}' > "$TMP_DIR/rec_dr.json"
write_decision_record "$TMP_DIR/rec_dr.json" "$TMP_DIR/dr.json" 1 "" "" /dev/null "$TMP_DIR/records/DR-X.1.json" 2>/dev/null || true
printf '{"id":"DR-Y","kind":"must-not-flag","forbidden_claim":"wrong"}\n' > "$TMP_DIR/dr_y.json"
jq '.findings[0].severity = "medium"' "$TMP_DIR/rec_dr.json" > "$TMP_DIR/rec_dr_y.json"
write_decision_record "$TMP_DIR/rec_dr_y.json" "$TMP_DIR/dr_y.json" 1 "" "" /dev/null "$TMP_DIR/records/DR-Y.1.json" 2>/dev/null || true
# An asked-but-unanswered question (the key exists, null) and a real,
# human-labelled Low false positive (review of PR 179, items 3 and 4).
printf '{"id":"MC-Z","kind":"must-catch","min_severity":"MEDIUM"}\n' > "$TMP_DIR/mc_z.json"
jq -n '{status:"complete", merged_chunks:[0], decisions_summary:{provider:"P", model:"M", scored:1},
  findings:[{"#":1, severity:"medium", verified:true, title:"t", why_it_matters:"w",
    decisions:{supported:0.5, severity:{choice:"medium"}, pre_existing:0.1, actionability:{score:1},
               diff_hunk_found:true, fix_skip:null}}]}' > "$TMP_DIR/rec_null.json"
write_decision_record "$TMP_DIR/rec_null.json" "$TMP_DIR/mc_z.json" 1 "" "" /dev/null "$TMP_DIR/records/MC-Z.1.json" 2>/dev/null || true
check "Test 8a2: a record tells an unanswered question (asked, null) from one never asked" "true null|false null" \
  "$(jq -r '.findings[0] | "\(.fix_skip_asked) \(.fix_skip)"' "$TMP_DIR/records/MC-Z.1.json")|$(jq -n '{status:"complete", merged_chunks:[0], decisions_summary:{scored:1}, findings:[{"#":1, severity:"low", verified:true, title:"t", decisions:{supported:0.5}}]}' > "$TMP_DIR/rec_na.json"; write_decision_record "$TMP_DIR/rec_na.json" "$TMP_DIR/mc_z.json" 1 "" "" /dev/null "$TMP_DIR/rec_na_out.json" 2>/dev/null; jq -r '.findings[0] | "\(.fix_skip_asked) \(.fix_skip)"' "$TMP_DIR/rec_na_out.json")"
jq -n '{fixture:"PR1-abc-F2", kind:"must-not-flag", sample:1, variant:"real", status:"scored", label:"fp", label_reason:"invalid",
  min_severity:"HIGH", forbidden_claim:"",
  findings:[{severity:"low", verified:true, title:"nit", supported:0.2, diff_hunk_found:true,
             fix_skip_asked:true, fix_skip:"skip_invalid", fix_skip_p:0.9}]}' > "$TMP_DIR/records/REAL-LOW.1.json"
if command -v python3 >/dev/null 2>&1; then
  rep="$(python3 "$REPORT_PY" "$TMP_DIR/records" "T")"
  check "Test 8b2: an unanswered question stays in the denominator" "1|1" \
    "$(printf '%s\n' "$rep" | grep -c 'answered                     : 4/6  — unanswered ones stay unscored')|$(printf '%s\n' "$rep" | grep -c 'answered with a distribution : 4/6')"
  check "Test 8b3: a human-labelled Low false positive counts in the fix/skip accuracy (its label is the truth)" "1|1" \
    "$(printf '%s\n' "$rep" | grep -c 'P(skip), should be skipped     : n=3 ')|$(printf '%s\n' "$rep" | grep -c 'invalid      skip_invalid 1')"
  check "Test 8b: the report measures fix_skip and whether a distribution came back" "1|1|1" \
    "$(printf '%s\n' "$rep" | grep -c '1d. `fix_skip`')|$(printf '%s\n' "$rep" | grep -c 'answered with a distribution : 4/6')|$(printf '%s\n' "$rep" | grep -c 'separation (AUC)               : 1.00')"
  check "Test 8c: …and what ai-analyse's filter would have done: the Medium false positive goes, the High is out of its reach" "1" \
    "$(printf '%s\n' "$rep" | grep -cE '^ +fixskip@0\.50 +1/3 +2/2 +precision \+1$')"
  # Review 5331170285 finding 2: a predicted SKIP on a real fix is a prediction
  # error at any severity, but the filter withholds only Medium/Low with a
  # P(skip) at the threshold and a matching hunk. Three real fixes predicted
  # SKIP: a High, a Medium without a hunk, a Medium with one.
  mkdir -p "$TMP_DIR/records_ws"
  for spec in "HIGH high true" "MNOHUNK medium false" "MED medium true"; do
    set -- $spec
    jq -n --arg sev "$2" --argjson hunk "$3" '{fixture:"PR1-ws", kind:"must-catch", sample:1, variant:"real", status:"scored",
      label:"tp", label_reason:"fix", min_severity:"LOW",
      findings:[{severity:$sev, verified:true, title:"real", supported:0.9, diff_hunk_found:$hunk,
                 fix_skip_asked:true, fix_skip:"skip_intentional", fix_skip_p:0.9}]}' > "$TMP_DIR/records_ws/REAL-$1.1.json"
  done
  rep_ws="$(python3 "$REPORT_PY" "$TMP_DIR/records_ws" "T")"
  check "Test 8f: prediction errors and actual withholds are counted apart" "1|1" \
    "$(printf '%s\n' "$rep_ws" | grep -c 'predicted SKIP on one to fix   : 3/3   (prediction error, any severity)')|$(printf '%s\n' "$rep_ws" | grep -c 'of which filter@0.50 withholds: 1/3')"
  rep_old="$(python3 "$REPORT_PY" "$SCRIPT_DIR/eval/corpus/real-findings" "T")"
  check "Test 8d: records from before fix_skip render no fix_skip section or policy" "0" \
    "$(printf '%s\n' "$rep_old" | grep -cE '1d\. |fixskip@' || true)"
else
  echo "⏭️  python3 unavailable — report assertions skipped"
fi
check "Test 8e: the harvester keeps the full reviewed head, the base TIP under that name, and the gate's prediction" "1|1|1|0" \
  "$(grep -c 'head_full="\$(jq -r .\.head_sha' "$HARVEST")|$(grep -c 'fix_skip: (.decisions.fix_skip.choice // null)' "$HARVEST")|$(grep -c '{ base_tip: \$base_tip }' "$HARVEST")|$(grep -cE '\{ base: ' "$HARVEST" || true)"

# --- 9. workflow wiring ---------------------------------------------------------------------
echo ""
echo "--- workflows ---"
check "Test 9a: the analyse guard reads both marker forms and exports the reviewed commit" "1|1|1" \
  "$(grep -c 'ai-review-report run\\(-id\\)\\{0,1\\}=' "$ANALYSE_WF")|$(grep -c 'review_commit=\${review_commit}' "$ANALYSE_WF")|$(grep -c 'review_commit: \${{ steps.guard.outputs.review_commit }}' "$ANALYSE_WF")"
check "Test 9b: --rev is passed only from the review-diff.sh branch (older libs reject it)" "1" \
  "$(awk '/if \[ -f "\$\{REVIEW_SKILL_DIR\}\/scripts\/lib\/review-diff.sh" \]; then/{f=1} f && /rev_args=\(--rev "\$reviewed_sha"\)/{print 1; exit} f && /^            elif/{exit}' "$ANALYSE_WF")"
check "Test 9c: an unavailable reviewed diff skips the decision step" "1" \
  "$(grep -c 'if \[ "\$diff_revision" = "unavailable" \]; then' "$ANALYSE_WF")"
check "Test 9c2: the decision block starts from a clean slate (no stale status or withhold report)" "1|1" \
  "$(grep -c '^            rm -rf ci_temp/decisions$' "$ANALYSE_WF")|$(awk '/^            rm -rf ci_temp\/decisions$/{getline; print}' "$ANALYSE_WF" | grep -c 'rm -f ci_temp/filter_reports/\*_decisions_withheld ')"
check "Test 9c3: an unavailable reviewed diff sets the status itself instead of reading a file" "1" \
  "$(awk '/if \[ "\$diff_revision" = "unavailable" \]; then/{f=1} f && /decisions_status="unavailable"/{print 1; exit} f && /^            else$/{exit}' "$ANALYSE_WF")"
check "Test 9d: the analyse run uploads its artifact, always" "1|1" \
  "$(grep -c 'name: ai-analyse-run-\${{ github.run_id }}' "$ANALYSE_WF")|$(awk '/- name: Upload ai-analyse run artifacts/{getline; print}' "$ANALYSE_WF" | grep -c 'if: always()')"
# Review 5331170285 finding 3: named files only — never the whole decisions
# directory, which also holds the raw PR diff and body and the gate's artifact.
run_files="$(grep -m1 '^      ANALYSE_RUN_FILES: ' "$ANALYSE_WF" | sed 's/^      ANALYSE_RUN_FILES: //')"
check "Test 9d2: the run files are named: scorer output yes; the decisions dir, PR diff, PR body and gate artifact no" "1|0|0" \
  "$(printf '%s\n' $run_files | grep -c '^decisions/out$')|$(printf '%s\n' $run_files | grep -cE '^decisions/?$' || true)|$(printf '%s\n' $run_files | grep -cE 'pr_diff|pr_body|artifact' || true)"
# Finding 6: a suite may clean ci_temp/, so the files are snapshotted outside
# the checkout BEFORE the test gate, collected without overwriting that
# snapshot, and uploaded from there.
check "Test 9d3: snapshot before the test gate, no-clobber collection, upload from runner.temp" "1|1|1|1" \
  "$(awk '/for f in \$ANALYSE_RUN_FILES; do/{s=NR} /scripts\/lib\/run-test-gate.sh/{print (s && s < NR) ? 1 : 0; exit}' "$ANALYSE_WF")|$(awk '/- name: Collect ai-analyse run artifacts/{f=1} f && /if: always\(\)/{print 1; exit}' "$ANALYSE_WF")|$(grep -c 'cp -Rn "ci_temp/\$f"' "$ANALYSE_WF")|$(grep -c 'path: \${{ runner.temp }}/ai-analyse-run/' "$ANALYSE_WF")"
check "Test 9e: the analyse job forwards the code-context Variable" "1" \
  "$(grep -c "OPENCODE_REVIEW_REPORT_DECISIONS_CODE_CONTEXT: \${{ vars.OPENCODE_REVIEW_REPORT_DECISIONS_CODE_CONTEXT || '1' }}" "$ANALYSE_WF")"
for t in test-decisions-hardening.sh ../../ai-analyse/scripts/test-filter-failing-test-findings.sh \
         ../../ai-analyse/scripts/test-filter-test-self-fix.sh ../../ai-analyse/scripts/test-run-test-gate.sh; do
  base="${t##*/}"
  check "Test 9f: the blocking regression job runs $base" "1" "$(grep -c "/scripts/${base}\$" "$HARNESS_WF")"
done

echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
SUITE_COMPLETED=1
[ "$fail" -eq 0 ]
