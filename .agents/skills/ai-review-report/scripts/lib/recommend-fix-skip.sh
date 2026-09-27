#!/bin/bash
# recommend-fix-skip.sh — decision-model FIX/SKIP recommendations for the
# findings of a POSTED gate review (LADR-097; LADR-096 roadmap phase 6).
#
# Usage:
#   recommend-fix-skip.sh --scope review|analyse --review <body.md> --out-dir <dir>
#                         [--diff <pr_diff>] [--skip-areas <file>] [--rules <file>]
#                         [--artifact <findings.merged.json>] [--severities <list>]
#                         [--rev <reviewed_sha>]
#
#   --artifact  the run artifact's findings.merged.json. Beyond quoted evidence
#               (lib/review-findings-to-json.sh) its directory supplies, since
#               LADR-098, the gate's own fix_skip answers, the Skip Areas the
#               gate judged against (decision_skip_areas.md) and the per-chunk
#               rules (rules/chunk_<n>/AGENTS.md).
#   --rev       the commit the review judged (lib/review-diff.sh), so a
#               re-score reads the enclosing code at that revision.
#
# Reuse before re-asking (LADR-098)
# ---------------------------------
# The gate asks fix_skip with the richest context there is: quoted evidence,
# the chunk's own rules and the code graph. A finding whose gate answer is
# present is therefore REUSED, not re-asked, when the answer is still valid:
#   - the Skip Areas the gate saw equal the PR's current ones (a new skip
#     bullet changes `previously skipped`, so it forces a re-score), and
#   - the gate used the decision provider this scope asks for (and the same
#     model, when one is set).
# Everything else is re-scored with --purpose fix_skip, the artifact's per-chunk
# rules when present, and the reviewed revision. The table says which is which.
#
#   --scope review   `/ai-review --usedecisions` (local, human decides). The
#                    switch IS the opt-in, and the gate's own Variables are
#                    used unchanged: OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER,
#                    _MODEL, _MIN_PROBABILITY, _TIMEOUT (_MODE is reported but
#                    changes nothing — a human flow has nothing to filter).
#   --scope analyse  `ai-analyse` (CI, autonomous). Off unless
#                    OPENCODE_ANALYSE_ENABLE_DECISIONS is truthy, and reads the
#                    cloned OPENCODE_ANALYSE_DECISIONS_* namespace (see below).
#
# Outputs, in --out-dir:
#   findings.json        the findings parsed from the body (+ artifact evidence)
#   decisions.json       the same document after scoring (`decisions.fix_skip`,
#                        `decisions.decision_source`: gate | rescored)
#   recommendations.tsv  one row per SCORED finding (header on line 1; the last
#                        column is the source)
#   recommendations.md   the human-facing table
#   withhold.txt         analyse + filter only: finding numbers to withhold
#   status               one word: off | no_findings | unavailable | scored
# and the table on stdout. Always exits 0 (64 on a usage error): this is
# enrichment, like the gate's scorer, and a failure leaves every caller exactly
# where it would have been without it.
#
# The analyse namespace — clones of the gate's six Variables
# -----------------------------------------------------------
#   OPENCODE_ANALYSE_ENABLE_DECISIONS          [0]  never inherited: the gate
#       scoring its review and an autonomous fixer acting on scores are
#       separate risk decisions (same reasoning as OPENCODE_ANALYSE_RUN_ON_DRAFT)
#   OPENCODE_ANALYSE_DECISIONS_PROVIDER        → else the gate's provider
#   OPENCODE_ANALYSE_DECISIONS_MODEL           → else the gate's model, but ONLY
#       when the provider was inherited too: the two surfaces spell the model
#       differently (jev-1.13 vs typesafe/jev-1.13), so a provider set without
#       a model means that provider's default — exactly the OPENCODE_ANALYSE_
#       PROVIDER / OPENCODE_ANALYSE_MODEL rule for the chat model.
#   OPENCODE_ANALYSE_DECISIONS_MODE            [annotate] own; not inherited,
#       because `filter` means something different here (below)
#   OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY [0.5] own: the P(skip) at or
#       above which `filter` withholds a finding
#   OPENCODE_ANALYSE_DECISIONS_TIMEOUT         → else the gate's → 20
#
# What the modes mean for ai-analyse — and the fence
# --------------------------------------------------
# annotate: every scored Medium/Low finding in the fixer's prompt carries the
#           recommendation and its probabilities; the fixer still decides.
# filter:   additionally, a finding the model recommends skipping (choice is a
#           skip class AND P(skip) >= the threshold) is WITHHELD from the
#           fixer's scope before it sees it, and listed in the summary
#           comment — the LADR-056 pattern.
# Both are ONE-DIRECTIONAL: the decision model can only narrow what the
# autonomous fixer may touch or advise it, never add a finding to its scope or
# turn a SKIP into a FIX. Withholding is the conservative direction for an
# autonomous fixer (fewer unattended edits), which is why `filter` needs no
# coverage fence here while the gate's softening `filter` does. An unscored
# finding, or one whose diff hunk was not found, is never withheld: failure
# falls back to exactly today's behaviour.
#
# Never a label: nothing here may be written into an `ai-review-decisions`
# block (LADR-096). These are model predictions of the human's decision.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scope=""; review=""; out_dir=""; diff=""; skip_areas=""; rules=""; artifact=""; severities=""; rev=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) scope="${2:-}"; shift 2 ;;
    --review) review="${2:-}"; shift 2 ;;
    --out-dir) out_dir="${2:-}"; shift 2 ;;
    --diff) diff="${2:-}"; shift 2 ;;
    --skip-areas) skip_areas="${2:-}"; shift 2 ;;
    --rules) rules="${2:-}"; shift 2 ;;
    --artifact) artifact="${2:-}"; shift 2 ;;
    --severities) severities="${2:-}"; shift 2 ;;
    --rev) rev="${2:-}"; shift 2 ;;
    *) echo "recommend-fix-skip.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done
case "$scope" in review|analyse) ;; *) echo "recommend-fix-skip.sh: --scope must be review or analyse" >&2; exit 64 ;; esac
if [ -z "$review" ] || [ -z "$out_dir" ]; then
  echo "recommend-fix-skip.sh: --review and --out-dir are required" >&2
  exit 64
fi

mkdir -p "$out_dir"
rm -f "$out_dir/findings.json" "$out_dir/decisions.json" "$out_dir/recommendations.tsv" \
      "$out_dir/recommendations.md" "$out_dir/withhold.txt" "$out_dir/rescore.json" "$out_dir/base.json"
status() { printf '%s\n' "$1" > "$out_dir/status"; }

info() { echo "ℹ️  Decision model (LADR-097, ${scope}): $*"; }
warn() { echo "⚠️  Decision model (LADR-097, ${scope}): $*"; }

# Bash 3.2 safe (no ${v,,}): /ai-review runs this on a developer's macOS.
is_truthy() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'
}

# --- Namespace --------------------------------------------------------------------
if [ "$scope" = "analyse" ]; then
  if ! is_truthy "${OPENCODE_ANALYSE_ENABLE_DECISIONS:-0}"; then
    status off
    exit 0
  fi
  if [ -n "${OPENCODE_ANALYSE_DECISIONS_PROVIDER:-}" ]; then
    d_provider="$OPENCODE_ANALYSE_DECISIONS_PROVIDER"
    d_model="${OPENCODE_ANALYSE_DECISIONS_MODEL:-}"
    d_from="OPENCODE_ANALYSE_DECISIONS_PROVIDER"
  else
    d_provider="${OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER:-}"
    d_model="${OPENCODE_ANALYSE_DECISIONS_MODEL:-${OPENCODE_REVIEW_REPORT_DECISIONS_MODEL:-}}"
    d_from="inherited from OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER"
  fi
  d_mode="${OPENCODE_ANALYSE_DECISIONS_MODE:-annotate}"
  d_min="${OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY:-0.5}"
  d_timeout="${OPENCODE_ANALYSE_DECISIONS_TIMEOUT:-${OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT:-20}}"
  min_var="OPENCODE_ANALYSE_DECISIONS_MIN_PROBABILITY"
  info "OPENCODE_ANALYSE_DECISIONS_* in use (provider ${d_from}); a resolver message below that names OPENCODE_REVIEW_REPORT_DECISIONS_* refers to these values"
else
  d_provider="${OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER:-}"
  d_model="${OPENCODE_REVIEW_REPORT_DECISIONS_MODEL:-}"
  d_mode="${OPENCODE_REVIEW_REPORT_DECISIONS_MODE:-annotate}"
  d_min="${OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY:-0.5}"
  d_timeout="${OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT:-20}"
  min_var="OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY"
fi

d_mode="$(printf '%s' "$d_mode" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$d_mode" in
  annotate|filter) ;;
  *) warn "unknown mode '${d_mode}' — using annotate"; d_mode="annotate" ;;
esac
if [ "$scope" = "review" ] && [ "$d_mode" = "filter" ]; then
  info "OPENCODE_REVIEW_REPORT_DECISIONS_MODE=filter is a gate setting; /ai-review only recommends — every finding is still listed"
fi
if ! [[ "$d_min" =~ ^(0(\.[0-9]+)?|1(\.0+)?|\.[0-9]+)$ ]]; then
  warn "invalid ${min_var}='${d_min}' (expected 0-1) — using 0.5"
  d_min="0.5"
fi
case "$d_min" in .*) d_min="0${d_min}" ;; esac

if ! command -v jq >/dev/null 2>&1; then
  warn "jq unavailable — no recommendations"
  status unavailable
  exit 0
fi

# --- Findings ----------------------------------------------------------------------
bash "$LIB_DIR/review-findings-to-json.sh" "$review" "$artifact" "$severities" > "$out_dir/findings.json"
n="$(jq '.findings | length' "$out_dir/findings.json" 2>/dev/null || echo 0)"
if [ "${n:-0}" -eq 0 ]; then
  info "no gate-numbered findings${severities:+ (${severities})} in the review body — nothing to score. Only an OpenCode Review Report rendered from structured findings (LADR-055) carries them."
  status no_findings
  exit 0
fi
enriched="$(jq '[.findings[] | select(.enriched_from_artifact == true)] | length' "$out_dir/findings.json")"
info "${n} finding(s) to score; ${enriched} carry quoted evidence from the run artifact"
[ -n "$diff" ] && [ -s "$diff" ] || warn "no PR diff available — every finding is judged without its diff hunk"

# --- Reuse the gate's answers (LADR-098) ---------------------------------------------
art_dir=""
[ -n "$artifact" ] && [ -s "$artifact" ] && art_dir="$(cd "$(dirname "$artifact")" && pwd)"
# Whitespace-insensitive, so a re-wrapped description is not a new decision.
norm() { [ -f "${1:-}" ] && tr -s '[:space:]' ' ' < "$1" | sed 's/^ //; s/ $//'; }
reuse_note=""
reuse=false
if [ -n "$art_dir" ] && jq -e '[.findings[] | select(.gate_decisions.fix_skip.choice != null)] | length > 0' "$out_dir/findings.json" >/dev/null 2>&1; then
  want_provider="$(printf '%s' "${d_provider:-OPENCODE-GO-DECISIONS}" | tr '[:lower:]' '[:upper:]')"
  gate_provider="$(jq -r '[.findings[].gate_decisions.provider // empty] | first // ""' "$out_dir/findings.json")"
  gate_model="$(jq -r '[.findings[].gate_decisions.model // empty] | first // ""' "$out_dir/findings.json")"
  if [ ! -f "$art_dir/decision_skip_areas.md" ]; then
    reuse_note="the run artifact does not record the Skip Areas the gate judged against"
  elif [ "$(norm "$art_dir/decision_skip_areas.md")" != "$(norm "${skip_areas:-/dev/null}")" ]; then
    reuse_note="the PR's Skip Areas changed since the gate scored"
  elif [ "$gate_provider" != "$want_provider" ]; then
    reuse_note="the gate used ${gate_provider:-another provider}, this scope asks for ${want_provider}"
  elif [ -n "$d_model" ] && [ "$gate_model" != "$d_model" ]; then
    reuse_note="the gate used model ${gate_model}, this scope asks for ${d_model}"
  else
    reuse=true
  fi
fi
if [ "$reuse" = true ]; then
  jq '.findings |= map(if .gate_decisions.fix_skip.choice != null
                        then .decisions = .gate_decisions + { decision_source: "gate" } else . end)' \
    "$out_dir/findings.json" > "$out_dir/base.json"
else
  cp "$out_dir/findings.json" "$out_dir/base.json"
  [ -z "$reuse_note" ] || info "gate answers not reused — ${reuse_note}; re-scoring"
fi
n_reused="$(jq '[.findings[] | select(.decisions.decision_source == "gate")] | length' "$out_dir/base.json")"

# --- Score what is left --------------------------------------------------------------
# The scorer takes the gate's variable names; the mapping above decides what
# they hold. MODE is always annotate there: this script owns what a
# recommendation does, the scorer's `filter` acts on the gate's verdict.
jq '.findings |= map(select(.decisions == null) | del(.gate_decisions))' "$out_dir/base.json" > "$out_dir/rescore.json"
n_rescore="$(jq '.findings | length' "$out_dir/rescore.json")"
if [ "$n_rescore" -gt 0 ]; then
  rules_arg="$rules"
  [ -z "$rules_arg" ] && [ -n "$art_dir" ] && [ -d "$art_dir/rules" ] && rules_arg="$art_dir/rules"
  _DECISIONS_PURPOSE=fix_skip \
  _DECISIONS_SOURCE_REV="$rev" \
  OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 \
  OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER="$d_provider" \
  OPENCODE_REVIEW_REPORT_DECISIONS_MODEL="$d_model" \
  OPENCODE_REVIEW_REPORT_DECISIONS_MODE=annotate \
  OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY="$d_min" \
  OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT="$d_timeout" \
    bash "$LIB_DIR/score-findings-decisions.sh" \
      "$out_dir/rescore.json" "$out_dir/.no-reviews" "" "${diff:-/dev/null}" "$rules_arg" "$skip_areas" || true
fi
if [ "$n_reused" -eq 0 ] && ! jq -e '.decisions_summary.purpose == "fix_skip"' "$out_dir/rescore.json" >/dev/null 2>&1; then
  warn "no recommendations (see the scorer's message above) — continuing without them"
  status unavailable
  exit 0
fi

# One document: every finding in body order, with the decisions it got and
# where they came from. The summary is the re-score's when there was one.
jq --slurpfile r "$out_dir/rescore.json" --argjson reused "$n_reused" '
  ($r[0].findings // [] | map({ key: (.["#"] | tostring), value: .decisions }) | from_entries) as $new
  | .findings |= map(del(.gate_decisions)
      | if .decisions != null then .
        elif $new[.["#"] | tostring] != null
        then .decisions = $new[.["#"] | tostring] + { decision_source: "rescored" }
        else . end)
  | .decisions_summary = (($r[0].decisions_summary // { purpose: "fix_skip", scored: 0, skipped: 0 })
      + { reused: $reused }
      + (if ($r[0].decisions_summary // null) == null
         then { provider: ([.findings[].decisions.provider // empty] | first),
                model: ([.findings[].decisions.model // empty] | first) } else {} end))
' "$out_dir/base.json" > "$out_dir/decisions.json"
rm -f "$out_dir/base.json"
[ "$n_reused" -eq 0 ] || info "${n_reused} of ${n} finding(s) reuse the gate's answer (given with the gate's full context); $((n - n_reused)) re-scored"

# --- Recommendations ---------------------------------------------------------------
# rec: FIX, or SKIP with the model's class; the P(skip) shown is 1 - P(fix).
jq -r --argjson min "$d_min" '
  def pct: if . == null then "" else "\((. * 100) | round)" end;
  ["n","severity","recommendation","class","skip_probability","decision_score","unsupported",
   "rule_allowed","previously_skipped","actionability","diff_hunk_found","file","line","title","skip_probability_raw",
   "source"],
  ( .findings[] | select(.decisions.fix_skip != null)
    | .decisions as $d
    | [ (.["#"] | tostring), .severity,
        (if $d.fix_skip.choice == "fix" then "FIX" else "SKIP" end),
        ($d.fix_skip.choice | sub("^skip_"; "")),
        ($d.fix_skip.skip_probability | pct),
        ($d.supported | pct),
        (if $d.supported < $min then "yes" else "no" end),
        ($d.sanctioned | pct),
        ($d.previously_skipped | pct),
        (if $d.actionability.score == null then "" else ($d.actionability.score * 10 | round / 10 | tostring) end),
        (if $d.diff_hunk_found == false then "no" else "yes" end),
         .file, (.line | tostring), (.title | gsub("[\t\n]"; " ")),
         ($d.fix_skip.skip_probability // ""),
         ($d.decision_source // "rescored") ] )
  | @tsv' "$out_dir/decisions.json" > "$out_dir/recommendations.tsv"

if [ "$scope" = "analyse" ] && [ "$d_mode" = "filter" ]; then
  # Compare the raw probability; the rounded percentage is display-only.
  # A missing distribution never qualifies for withholding.
  awk -F '\t' -v min="$d_min" 'NR > 1 && $3 == "SKIP" && $15 != "" && $15 + 0 >= min && $11 == "yes" { print $1 }' \
    "$out_dir/recommendations.tsv" > "$out_dir/withhold.txt"
fi

# The table. `1.` not `#1` (LADR-067): GitHub autolinks # + digits.
provider_model="$(jq -r '.decisions_summary | "\(.provider)/\(.model)"' "$out_dir/decisions.json")"
scored="$(( $(wc -l < "$out_dir/recommendations.tsv" | tr -d ' ') - 1 ))"
n_rescored=$(( scored - n_reused ))
n_unscored=$(( n - scored ))
{
  echo "**Decision model** \`${provider_model}\` — FIX/SKIP recommendations for ${scored} of ${n} finding(s) (${scope} scope, ${d_mode}; ${n_reused} from the gate's own scoring, ${n_rescored} re-scored$( [ "$n_unscored" -eq 0 ] || printf ', %s not scored — no row' "$n_unscored")). Advisory predictions of the human decision, never labels."
  echo ""
  echo "| # | Priority | File | Decision model | P(skip) | Decision score | Rule-allowed | Previously skipped | Actionability (0-2) | Source |"
  echo "|---|----------|------|----------------|---------|----------------|--------------|--------------------|---------------------|--------|"
  awk -F '\t' '
    function p(v) { return (v == "") ? "—" : v "%" }
    NR > 1 {
      sev = ($2 == "critical") ? "🔴 Critical" : ($2 == "high") ? "🟠 High" : ($2 == "medium") ? "🟡 Medium" : "🔵 Low"
      rec = ($3 == "FIX") ? "FIX" : "SKIP (" $4 ")"
      ds = p($6); if ($7 == "yes") ds = ds " [UNSUPPORTED]"
      if ($11 == "no") ds = ds " (no diff hunk)"
      src = ($16 == "gate") ? "gate" : "re-scored"
      printf "| %s. | %s | `%s:%s` | %s | %s | %s | %s | %s | %s | %s |\n", $1, sev, $12, $13, rec, p($5), ds, p($8), p($9), ($10 == "" ? "—" : $10), src
    }' "$out_dir/recommendations.tsv"
  if [ -s "$out_dir/withhold.txt" ]; then
    echo ""
    echo "Withheld from the autonomous fixer (filter, P(skip) ≥ $(awk -v m="$d_min" 'BEGIN { printf "%d", m * 100 }')%): $(sed 's/$/./' "$out_dir/withhold.txt" | paste -sd ' ' -)"
  fi
} > "$out_dir/recommendations.md"
status scored
cat "$out_dir/recommendations.md"
exit 0
