#!/bin/bash
# score-findings-decisions.sh — score the merged findings with a structured
# decision model and write its typed verdicts back into the document (LADR-091).
#
# Usage: score-findings-decisions.sh <merged_json> [reviews_dir] [total_chunks] [pr_diff]
#   merged_json  : ci_temp/findings.merged.json, rewritten in place (tmp + mv)
#   reviews_dir  : ci_temp/reviews — read for chunk_<n>.failed flags (filter fence)
#   total_chunks : chunk count of this run — the filter fence needs it
#   pr_diff      : ci_temp/pr_diff.txt — source of the per-finding diff hunk
#
# Always exits 0. This is enrichment, exactly like the graph analysis, RTK and
# check-versions: every failure path logs one ⚠️ line and leaves the merged
# document byte-identical, never writes a chunk_<n>.failed flag (LADR-031 owns
# that channel), and never changes the gate's exit code.
#
# Why raw HTTP and not `opencode run`
# -----------------------------------
# A decision model (first: TypeSafe Jev) is not a chat model. It takes `state`
# plus typed `questions` (noul / choice / score) and returns probabilities; it
# has no chat, messages or responses surface, so opencode cannot drive it. This
# is therefore the first model call in the gate outside lib/opencode-with-
# fallback.sh, in the same class as lib/check-versions.sh: curl + jq. None of
# opencode's machinery covers it — no health probe, no model-chain fallback, no
# output-shape check — which is why this script runs its OWN preflight before
# spending a request per finding.
#
# What it writes
# --------------
# Per finding in `.findings`, an optional `decisions` object (supported,
# severity, pre_existing, actionability). At top level, `decisions_summary`
# (the PR-level block_merge / dominant_risk / overall_risk answers plus counts).
# The chunk model's own `severity`, `confidence` and `verified` are NEVER
# rewritten. In `filter` mode a non-critical finding whose `supported`
# probability is below the threshold is moved out of `.findings` into
# `decisions_summary.suppressed`, and the survivors are renumbered 1..N so every
# severity section stays contiguous (LADR-068's ordered-list invariant).
#
# Filter is a SOFTENING path — a suppressed High can no longer force
# request_changes — so it runs only inside the fence the Recommendation sync
# uses (lib/sync-recommendation-from-findings.sh): no failed chunk, and every
# chunk present in the merge's own `merged_chunks`. Outside that fence it
# degrades to annotate and says so. It never suppresses `critical`.
set -uo pipefail
umask 077

merged="${1:-ci_temp/findings.merged.json}"
reviews_dir="${2:-ci_temp/reviews}"
total_chunks="${3:-}"
pr_diff="${4:-ci_temp/pr_diff.txt}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
QUESTIONS="$SKILL_ROOT/assets/decisions-questions.json"
RESOLVER="$LIB_DIR/resolve-provider.sh"

# Request budget. Jev's hard limit is 32,000 tokens per request; this keeps a
# request under ~24k at a conservative 3 bytes per token (code tokenises worse
# than prose), leaving headroom for the questions and the answer.
BUDGET_BYTES=72000
# Initial cap on one finding's diff hunk, before the budget check trims further.
HUNK_MAX_BYTES=24000
# Concurrent per-finding requests. Plain batches, not `wait -n`: this script is
# also reached from local-review.sh, which carries no Bash >= 4 guard.
PARALLEL=4
# Upper bound on scored findings, so the worst case (every request timing out)
# stays bounded at ceil(MAX_FINDINGS / PARALLEL) x the timeout Variable.
MAX_FINDINGS=60
# One retry for the two statuses the vendor documents as transient.
RETRY_DELAY="${_DECISIONS_RETRY_DELAY:-2}"

info() { echo "ℹ️  Decision model (LADR-091): $*"; }
warn() { echo "⚠️  Decision model (LADR-091): $*"; }

# Same truthy idiom as ENABLE_STRUCTURED_FINDINGS, without `${v,,}` (Bash 3.2).
is_truthy() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'
}

is_truthy "${OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS:-0}" || exit 0

if ! command -v jq >/dev/null 2>&1; then
  warn "jq unavailable — merged findings left untouched"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  warn "curl unavailable — merged findings left untouched"
  exit 0
fi
if [ ! -s "$merged" ] || ! jq -e '.status == "complete"' "$merged" >/dev/null 2>&1; then
  info "no merged findings document — step skipped"
  exit 0
fi
if jq -e 'has("decisions_summary")' "$merged" >/dev/null 2>&1; then
  info "merged findings already carry decisions — not scoring twice"
  exit 0
fi
if [ ! -s "$QUESTIONS" ] || ! jq -e '.per_finding and .pr_level and .preflight' "$QUESTIONS" >/dev/null 2>&1; then
  warn "questions asset missing or unparseable (${QUESTIONS}) — merged findings left untouched"
  exit 0
fi

n_findings="$(jq '(.findings // []) | length' "$merged")"
n_soft="$(jq '((.residual_risks // []) | length) + ((.testing_gaps // []) | length)' "$merged")"
if [ "$n_findings" -eq 0 ] && [ "$n_soft" -eq 0 ]; then
  info "no findings to score — step skipped"
  exit 0
fi

# --- Provider ------------------------------------------------------------------
# Resolved in a throwaway subshell first: the resolver's failure path is `exit
# 1` with a ❌ line, which is right for the review scope and wrong for a
# best-effort step. The real resolution below then cannot fail.
# shellcheck disable=SC1090
if ! _rp_err="$( (OPENCODE_PROVIDER_SCOPE=decisions; . "$RESOLVER") 2>&1 >/dev/null )"; then
  warn "decisions provider unavailable (${_rp_err#❌ }) — merged findings left untouched"
  exit 0
fi
# Read by the sourced resolver, not by this script.
# shellcheck disable=SC2034
OPENCODE_PROVIDER_SCOPE=decisions
# shellcheck disable=SC1090
. "$RESOLVER"
unset OPENCODE_PROVIDER_SCOPE
provider="$OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER"
model="$OPENCODE_REVIEW_REPORT_DECISIONS_MODEL"
url="$OPENCODE_REVIEW_REPORT_DECISIONS_URL"

mode_requested="$(printf '%s' "${OPENCODE_REVIEW_REPORT_DECISIONS_MODE:-annotate}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$mode_requested" in
  annotate|filter) ;;
  *) warn "unknown OPENCODE_REVIEW_REPORT_DECISIONS_MODE='${mode_requested}' — using annotate"; mode_requested="annotate" ;;
esac
mode="$mode_requested"
mode_note=""

min_probability="${OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY:-0.5}"
if ! [[ "$min_probability" =~ ^(0(\.[0-9]+)?|1(\.0+)?|\.[0-9]+)$ ]]; then
  warn "invalid OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY='${min_probability}' (expected 0-1) — using 0.5"
  min_probability="0.5"
fi
case "$min_probability" in .*) min_probability="0${min_probability}" ;; esac

timeout="${OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT:-20}"
if ! [[ "$timeout" =~ ^[1-9][0-9]*$ ]]; then
  warn "invalid OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT='${timeout}' (expected a positive integer) — using 20"
  timeout=20
fi

# --- Filter fence --------------------------------------------------------------
# The same evidence the Recommendation sync requires before it may soften: a
# merged set that provably holds every reviewed chunk's findings. Stricter than
# the sync on one axis — any failed chunk degrades, whether or not the
# orchestrator summary later succeeds, because this step runs before
# aggregation and cannot know.
if [ "$mode" = "filter" ]; then
  fence=""
  if ! [[ "$total_chunks" =~ ^[1-9][0-9]*$ ]]; then
    fence="the chunk total is unknown"
  else
    failed="$(find "$reviews_dir" -maxdepth 1 -name 'chunk_*.failed' 2>/dev/null | wc -l | tr -d ' ')"
    [ "${failed:-0}" -eq 0 ] || fence="${failed} chunk(s) failed"
    missing="$(jq -r --argjson total "$total_chunks" '
      (.merged_chunks // []) as $have
      | [ range(0; $total) | select(. as $c | ($have | index($c)) == null) ]
      | map(tostring) | join(", ")' "$merged" 2>/dev/null || echo "?")"
    [ -z "$missing" ] || fence="${fence:+${fence}; }chunk(s) ${missing} contributed no structured findings"
  fi
  if [ -n "$fence" ]; then
    mode="annotate"
    mode_note="filter degraded to annotate: ${fence}"
    info "filter mode degraded to annotate — partial coverage (${fence}). Suppression can soften the verdict, so it only runs on a merged set that provably holds every chunk's findings."
  fi
fi

work="$(mktemp -d 2>/dev/null || echo "${merged}.decisions.d")"
mkdir -p "$work"
trap 'rm -rf "$work" "${merged}.decisions.tmp"' EXIT

# The key goes to curl through a 0600 header file, never argv, so it cannot
# surface in a process listing on the runner.
printf 'Authorization: Bearer %s\n' "$OPENCODE_DECISIONS_API_KEY" > "$work/auth.hdr"
unset OPENCODE_DECISIONS_API_KEY

# post <request> <response> — prints the HTTP status (000 on timeout/network).
# Returns 0 only for a 200 whose body carries an `answers` object.
post() {
  local req="$1" resp="$2" code attempt=1
  while :; do
    code="$(curl -sS -o "$resp" -w '%{http_code}' --max-time "$timeout" \
      -H @"$work/auth.hdr" -H 'Content-Type: application/json' \
      --data-binary @"$req" "$url" 2>"${resp}.err")"
    code="${code:-000}"
    case "$code" in
      429|529)
        if [ "$attempt" -lt 2 ]; then
          attempt=2
          sleep "$RETRY_DELAY"
          continue
        fi
        ;;
    esac
    break
  done
  printf '%s' "$code"
  [ "$code" = "200" ] && jq -e '.answers | type == "object"' "$resp" >/dev/null 2>&1
}

# describe <code> <response> — one-line reason for a failed request.
describe() {
  local code="$1" resp="$2" msg
  msg="$(jq -r '(.error.message // .error // .message // empty) | tostring' "$resp" 2>/dev/null | head -c 160)"
  case "$code" in
    000) printf 'timeout or network error after %ss' "$timeout" ;;
    200) printf 'HTTP 200 without a usable answers object' ;;
    *)   printf 'HTTP %s%s' "$code" "${msg:+: $msg}" ;;
  esac
}

# --- Preflight -----------------------------------------------------------------
# One trivial noul. A dead endpoint, a refused key or an unknown model shows up
# here as one warning, instead of as N skipped findings nobody reads.
jq -c --arg model "$model" '{model: $model, state: .preflight.state, questions: .preflight.questions}' \
  "$QUESTIONS" > "$work/preflight.req"
code="$(post "$work/preflight.req" "$work/preflight.resp")"
if [ "$code" != "200" ] || ! jq -e '.answers.preflight.noul | type == "number"' "$work/preflight.resp" >/dev/null 2>&1; then
  warn "decisions provider unavailable (${provider}/${model}: $(describe "$code" "$work/preflight.resp")) — step disabled for this run, merged findings left untouched"
  exit 0
fi

# hunk <file> <line> — the diff hunk of <file> whose new-side range covers
# <line>, else the nearest one. Empty when the file is not in the diff.
hunk() {
  [ -s "$pr_diff" ] || return 0
  awk -v f="$1" -v L="$2" '
    function flush(  d) {
      if (h != "") {
        d = (L < hs) ? hs - L : ((L > he) ? L - he : 0)
        if (best == "" || d < bestd) { best = h; bestd = d }
      }
      h = ""
    }
    /^diff --git / {
      if (infile) flush()
      suffix = " b/" f
      infile = (length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix)
      next
    }
    !infile { next }
    /^@@ / {
      flush()
      hs = 0; he = 0
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
        n = split(substr($0, RSTART + 1, RLENGTH - 1), a, ",")
        hs = a[1] + 0
        cnt = (n > 1) ? a[2] + 0 : 1
        he = hs + ((cnt > 0) ? cnt : 1) - 1
      }
      h = $0 "\n"
      next
    }
    h != "" { h = h $0 "\n" }
    END { if (infile) flush(); printf "%s", best }
  ' "$pr_diff"
}

# build_finding_request <index> <hunk_file> <out>
build_finding_request() {
  jq -c --argjson i "$1" --rawfile hunk "$2" --slurpfile q "$QUESTIONS" --arg model "$model" '
    .findings[$i] as $f | $q[0] as $q
    | { model: $model,
        state: {
          finding: ($f | { title, severity, file, line, why_it_matters, evidence, first_evidence, pre_existing }
                       | with_entries(select(.value != null))),
          diff_hunk: $hunk,
          review_rules: $q.review_rules
        },
        questions: $q.per_finding }' "$merged" > "$3"
}

# --- Per-finding requests -------------------------------------------------------
to_score="$n_findings"
if [ "$to_score" -gt "$MAX_FINDINGS" ]; then
  info "${n_findings} findings — scoring the first ${MAX_FINDINGS} (severity order); the rest are counted as skipped"
  to_score="$MAX_FINDINGS"
fi

i=0
while [ "$i" -lt "$to_score" ]; do
  file="$(jq -r --argjson i "$i" '.findings[$i].file // ""' "$merged")"
  line="$(jq -r --argjson i "$i" '.findings[$i].line // 0 | tostring | (capture("^(?<n>[0-9]+)").n // "0")' "$merged")"
  hunk "$file" "$line" > "$work/f_${i}.hunk"
  # Every cut says so, in the text the model reads: an unmarked truncation
  # reads as "the change ends here", which is evidence of absence it is not.
  if [ "$(wc -c < "$work/f_${i}.hunk" | tr -d ' ')" -gt "$HUNK_MAX_BYTES" ]; then
    { head -c "$HUNK_MAX_BYTES" "$work/f_${i}.hunk"; printf '\n[... diff hunk truncated to fit the decision model context budget]\n'; } > "$work/f_${i}.hunk.cut"
    mv "$work/f_${i}.hunk.cut" "$work/f_${i}.hunk"
  fi
  build_finding_request "$i" "$work/f_${i}.hunk" "$work/f_${i}.req"
  size="$(wc -c < "$work/f_${i}.req" | tr -d ' ')"
  if [ "$size" -gt "$BUDGET_BYTES" ]; then
    # Trim the hunk — the only unbounded field — to what the budget leaves.
    hunk_size="$(wc -c < "$work/f_${i}.hunk" | tr -d ' ')"
    keep=$(( BUDGET_BYTES - (size - hunk_size) - 200 ))
    if [ "$keep" -gt 0 ]; then
      { head -c "$keep" "$work/f_${i}.hunk"; printf '\n[... diff hunk truncated to fit the decision model context budget]\n'; } > "$work/f_${i}.hunk.cut"
      mv "$work/f_${i}.hunk.cut" "$work/f_${i}.hunk"
      build_finding_request "$i" "$work/f_${i}.hunk" "$work/f_${i}.req"
      size="$(wc -c < "$work/f_${i}.req" | tr -d ' ')"
      info "finding $((i + 1)): diff hunk truncated to fit the ${BUDGET_BYTES}-byte request budget"
    fi
    if [ "$size" -gt "$BUDGET_BYTES" ]; then
      info "finding $((i + 1)): request is ${size} bytes even without its diff hunk — skipped"
      rm -f "$work/f_${i}.req"
    fi
  fi
  i=$((i + 1))
done

i=0
while [ "$i" -lt "$to_score" ]; do
  batch_end=$((i + PARALLEL))
  while [ "$i" -lt "$to_score" ] && [ "$i" -lt "$batch_end" ]; do
    if [ -f "$work/f_${i}.req" ]; then
      ( post "$work/f_${i}.req" "$work/f_${i}.resp" > "$work/f_${i}.code" ) &
    fi
    i=$((i + 1))
  done
  wait
done

# Validate every answer; an unusable one leaves that finding unscored (fail
# open — in filter mode an unscored finding is never suppressed).
: > "$work/decisions.jsonl"
first_failure=""
i=0
while [ "$i" -lt "$to_score" ]; do
  if [ -f "$work/f_${i}.code" ]; then
    code="$(cat "$work/f_${i}.code")"
    if [ "$code" = "200" ] && jq -c --argjson i "$i" --arg provider "$provider" --arg model "$model" '
        .answers as $a
        | def prob: type == "number" and . >= 0 and . <= 1;
          if ($a.supported.noul | prob)
             and (($a.severity.choice // "") | IN("critical", "high", "medium", "low"))
             and ($a.pre_existing.noul | prob)
             and ($a.actionability.score | type == "number")
          then { key: ($i | tostring),
                 value: { provider: $provider,
                          model: (.model // $model),
                          supported: $a.supported.noul,
                          severity: { choice: $a.severity.choice,
                                      probabilities: ($a.severity.probabilities // {}),
                                      confidence: ($a.severity.confidence // null) },
                          pre_existing: $a.pre_existing.noul,
                          actionability: { score: $a.actionability.score,
                                           confidence: ($a.actionability.confidence // null) } } }
          else error("malformed answer") end' "$work/f_${i}.resp" >> "$work/decisions.jsonl" 2>/dev/null; then
      :
    elif [ -z "$first_failure" ]; then
      if [ "$code" = "200" ]; then
        first_failure="finding $((i + 1)): malformed answer"
      else
        first_failure="finding $((i + 1)): $(describe "$code" "$work/f_${i}.resp")"
      fi
    fi
  fi
  i=$((i + 1))
done
scored="$(wc -l < "$work/decisions.jsonl" | tr -d ' ')"
skipped=$(( n_findings - scored ))
[ -z "$first_failure" ] || warn "${skipped} finding(s) left unscored — first failure: ${first_failure}"

jq -s 'from_entries' "$work/decisions.jsonl" > "$work/decisions.json"

# --- PR-level request -----------------------------------------------------------
build_pr_request() { # build_pr_request <jq-filter-for-findings> <out>
  jq -c --slurpfile d "$work/decisions.json" --slurpfile q "$QUESTIONS" --arg model "$model" "
    \$d[0] as \$dec | \$q[0] as \$q
    | { model: \$model,
        state: {
          findings: [ (.findings // []) | to_entries[] | select(.value | $1)
                      | { n: .value[\"#\"], severity: .value.severity, file: .value.file, line: .value.line,
                          title: .value.title, supported: (\$dec[.key | tostring].supported // null) } ],
          residual_risks: (.residual_risks // []),
          testing_gaps: (.testing_gaps // []),
          review_rules: { severity: \$q.review_rules.severity, decision_rule: \$q.review_rules.decision_rule }
        },
        questions: \$q.pr_level }" "$merged" > "$2"
}

pr_scope="all"
build_pr_request 'true' "$work/pr.req"
if [ "$(wc -c < "$work/pr.req" | tr -d ' ')" -gt "$BUDGET_BYTES" ]; then
  pr_scope="critical_high"
  info "PR-level state exceeds the request budget — sending only critical and high findings"
  build_pr_request '.severity == "critical" or .severity == "high"' "$work/pr.req"
  if [ "$(wc -c < "$work/pr.req" | tr -d ' ')" -gt "$BUDGET_BYTES" ]; then
    pr_scope="skipped"
    info "PR-level state exceeds the request budget even for critical and high findings — PR-level questions skipped"
  fi
fi

echo 'null' > "$work/pr.json"
if [ "$pr_scope" != "skipped" ]; then
  code="$(post "$work/pr.req" "$work/pr.resp")"
  if [ "$code" = "200" ] && jq -c '
      .answers as $a
      | if ($a.block_merge.noul | type == "number" and . >= 0 and . <= 1)
           and (($a.dominant_risk.choice // null) | type == "string")
           and ($a.overall_risk.score | type == "number")
        then { block_merge: $a.block_merge.noul,
               dominant_risk: { choice: $a.dominant_risk.choice,
                                probabilities: ($a.dominant_risk.probabilities // {}),
                                confidence: ($a.dominant_risk.confidence // null) },
               overall_risk: { score: $a.overall_risk.score,
                               legend: ($a.overall_risk.legend // {}),
                               probabilities: ($a.overall_risk.probabilities // {}),
                               confidence: ($a.overall_risk.confidence // null) } }
        else error("malformed answer") end' "$work/pr.resp" > "$work/pr.json" 2>/dev/null; then
    :
  else
    echo 'null' > "$work/pr.json"
    pr_scope="failed"
    warn "PR-level questions unanswered ($(describe "$code" "$work/pr.resp"))"
  fi
fi

if [ "$scored" -eq 0 ] && [ "$(cat "$work/pr.json")" = "null" ]; then
  warn "no usable answers from ${provider}/${model} — merged findings left untouched"
  exit 0
fi

# --- Write back -------------------------------------------------------------------
jq --slurpfile d "$work/decisions.json" --slurpfile pr "$work/pr.json" \
   --arg provider "$provider" --arg model "$model" \
   --arg mode "$mode" --arg mode_requested "$mode_requested" --arg mode_note "$mode_note" \
   --argjson min "$min_probability" --arg pr_scope "$pr_scope" \
   --argjson scored "$scored" --argjson skipped "$skipped" '
  $d[0] as $dec
  | def unsupported: (.decisions.supported // null) as $s
                     | $s != null and $s < $min and .severity != "critical";
  .findings |= [ to_entries[] | .value + (if $dec[.key | tostring] then { decisions: $dec[.key | tostring] } else {} end) ]
  | (if $mode == "filter" then [ .findings[] | select(unsupported) ] else [] end) as $drop
  | (if $mode == "filter" then
       .findings |= ([ .[] | select(unsupported | not) ] | to_entries | map(.value + { "#": (.key + 1) }))
     else . end)
  | .decisions_summary = (
      { provider: $provider,
        model: ([ $dec[] | .model ] | first // $model),
        mode: $mode,
        mode_requested: $mode_requested,
        mode_note: (if $mode_note == "" then null else $mode_note end),
        min_probability: $min,
        scored: $scored,
        skipped: $skipped,
        pr_level_scope: $pr_scope,
        suppressed: [ $drop[] | { number_before_filter: .["#"], title, severity, file, line,
                                  supported: .decisions.supported } ] }
      + ($pr[0] // { block_merge: null, dominant_risk: null, overall_risk: null }) )
' "$merged" > "${merged}.decisions.tmp" 2>"$work/write.err"

if ! jq -e '.status == "complete" and (.decisions_summary | type == "object")' "${merged}.decisions.tmp" >/dev/null 2>&1; then
  warn "could not write the enriched document ($(head -c 200 "$work/write.err" 2>/dev/null)) — merged findings left untouched"
  exit 0
fi
mv "${merged}.decisions.tmp" "$merged"

jq -r '.decisions_summary
  | "✅ Decision model \(.provider)/\(.model) (\(.mode)): scored \(.scored), skipped \(.skipped), suppressed \(.suppressed | length)"
    + (if .block_merge != null then " | block_merge \(.block_merge)" else "" end)
    + (if .dominant_risk != null then " | dominant risk \(.dominant_risk.choice)" else "" end)
    + (if .overall_risk != null then " | overall risk \(.overall_risk.score)" else "" end)' "$merged" 2>/dev/null || true
exit 0
