#!/bin/bash
# calibrate-decisions.sh — test the LADR-093 decision model on PLANTED findings
# whose truth is known by construction.
#
# The eval measurement in run-evals.sh can only judge findings the chunk model
# happens to raise, and a good reviewer raises almost no known false positives —
# so the precision side of "does Jev separate right from wrong" went unmeasured
# (run 36303910662: 0 re-raises, AUC n/a). This script removes that dependency:
# every must-not-flag manifest carries `known_false_positive` (the exact wrong
# claim the fixture exists to forbid, phrased to match its `forbidden_claim`)
# and every must-catch manifest carries `known_true_positive` (its seeded
# defect). Each is scored by the production scorer, alone, against the
# fixture's real diff. No chat model is called — only the decision provider.
#
# Two variants per fixture, because the fixtures explain themselves in code
# comments ("DO NOT flag … intentional", "BUG: … not thread-safe"):
#   as-is     comments kept — realistic, and it tests whether Jev follows the
#             review_rules.untrusted_content boundary or reads the answer key.
#   stripped  full-line and trailing comments removed from before/ and after/ —
#             Jev must judge the code alone. This is the honest discrimination
#             test; a large gap between the variants means Jev is reading the
#             comments, not the code.
#   stripped+rules
#             stripped, plus the corpus's project standards (the same DR
#             documents the chunk reviewer is given) as the scorer's rules file,
#             which adds the `sanctioned` question. Tests whether knowing the
#             project's decisions lets Jev reject the policy-exempt class, and
#             whether it checks a rule's conditions (DR-012 exempts expression
#             trees; MC-001 is a materialized NRE the rule does not cover).
#
# Usage: calibrate-decisions.sh [out_dir]
#   Uses OPENCODE_REVIEW_REPORT_DECISIONS_{PROVIDER,MODEL,TIMEOUT} and that
#   provider's key, exactly like the gate. Report-only; exits 0 unless its own
#   inputs are unusable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORPUS_DIR="${EVAL_CORPUS_DIR:-$SCRIPT_DIR/corpus}"
[ -d "$CORPUS_DIR" ] && CORPUS_DIR="$(cd "$CORPUS_DIR" && pwd)"
SCORER="$SKILL_SCRIPTS_DIR/lib/score-findings-decisions.sh"
REPORT="$SCRIPT_DIR/lib/decisions-report.py"
PARALLEL="${EVAL_PARALLEL:-4}"
case "$PARALLEL" in ''|*[!0-9]*|0) PARALLEL=4 ;; esac

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "❌ git is required" >&2; exit 2; }
[ -f "$SCORER" ] || { echo "❌ scorer not found at $SCORER" >&2; exit 2; }

OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/jev-calibration.XXXXXX")}"
mkdir -p "$OUT/as-is" "$OUT/stripped" "$OUT/stripped+rules" "$OUT/work"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/decision-record.sh"
# The project standards the chunk reviewer reads (run-evals.sh assembles the
# same two files into the fixture sandbox).
RULES="$OUT/work/project-rules.md"
{ cat "$CORPUS_DIR/context/code-review-standards.md"; printf '\n\n'
  cat "$CORPUS_DIR/context/code-review-standards-supplement.md"; } > "$RULES" 2>/dev/null || : > "$RULES"

# strip_comments <file> — in place, by extension. Conservative on purpose: a
# trailing `//` only counts with whitespace on both sides, so `https://…` in a
# string literal survives. JSON and project files have no comments to strip.
strip_comments() {
  case "$1" in
    *.cs|*.ts|*.js|*.java|*.go)
      sed -E -e '/^[[:space:]]*\/\//d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1" > "$1.tmp" && mv "$1.tmp" "$1" ;;
    *.yml|*.yaml|*.sh|*.py)
      sed -E '/^[[:space:]]*#/d' "$1" > "$1.tmp" && mv "$1.tmp" "$1" ;;
  esac
}

# calibrate_one <manifest> <variant> — writes $OUT/<variant>/<id>.1.json
calibrate_one() {
  local manifest="$1" variant="$2" fdir id key sb file line
  fdir="$(dirname "$manifest")"
  id="$(jq -r '.id' "$manifest")"
  key="$(jq -r 'if .kind == "must-not-flag" then "known_false_positive" else "known_true_positive" end' "$manifest")"
  jq -e --arg k "$key" '.[$k] | type == "object"' "$manifest" >/dev/null 2>&1 || return 0
  sb="$OUT/work/${variant}-${id}"
  rm -rf "$sb"; mkdir -p "$sb"
  (
    cd "$sb" || exit 0
    git init -q && git config user.email c@c && git config user.name c
    if [ -d "$fdir/before" ]; then cp -R "$fdir/before/." .; fi
    case "$variant" in stripped*) git ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do strip_comments "$f"; done ;; esac
    git add -A && git commit -q --allow-empty -m base
    git rm -rq --ignore-unmatch . >/dev/null 2>&1 || true
    cp -R "$fdir/after/." .
    case "$variant" in stripped*) find . -path ./.git -prune -o -type f -print0 | while IFS= read -r -d '' f; do strip_comments "$f"; done ;; esac
    git add -A && git commit -q --allow-empty -m head
    mkdir -p ci_temp/reviews
    git diff HEAD~1..HEAD > ci_temp/pr_diff.txt

    file="$(jq -r --arg k "$key" '.[$k].file' "$manifest")"
    evidence="$(jq -r --arg k "$key" '.[$k].evidence_line' "$manifest")"
    line="$(grep -nF -- "$evidence" "$file" 2>/dev/null | head -n1 | cut -d: -f1)"
    code="$(sed -n "${line:-0}p" "$file" 2>/dev/null | sed -E 's/^[[:space:]]+//')"
    jq -n --slurpfile man "$manifest" --arg k "$key" --argjson line "${line:-1}" --arg code "$code" '
      $man[0][$k] as $p
      | { status: "complete", merged_chunks: [0],
          findings: [ { "#": 1, title: $p.title, severity: $p.severity, file: $p.file, line: $line,
                        why_it_matters: $p.why_it_matters, confidence: 100, verified: true,
                        first_evidence: "\($p.file):\($line) -- \($code)",
                        pre_existing: false, requires_verification: false,
                        autofix_class: "manual", owner: "human", chunks: [0] } ],
          pre_existing_findings: [], suppressed_findings: [], residual_risks: [], testing_gaps: [],
          suppressed_by_confidence: {}, demoted_no_quote: 0, merged_duplicates: 0,
          malformed_returns: 0, malformed_findings: 0, malformed_reasons: {}, malformed_return_reasons: {} }' \
      > ci_temp/findings.merged.json

    rules_arg=""
    [ "$variant" = "stripped+rules" ] && rules_arg="$RULES"
    OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=1 OPENCODE_REVIEW_REPORT_DECISIONS_MODE=annotate \
      bash "$SCORER" ci_temp/findings.merged.json ci_temp/reviews 1 ci_temp/pr_diff.txt ${rules_arg:+"$rules_arg"} \
      > ci_temp/score.log 2>&1 || true

    # The shared writer (lib/decision-record.sh), so a calibration record and
    # an eval record mean the same thing: a finding whose answer was missing or
    # malformed makes the sample `unavailable`, never silently "scored".
    write_decision_record ci_temp/findings.merged.json "$manifest" 1 "$variant" 1 \
      ci_temp/score.log "$OUT/$variant/$id.1.json"
  )
  return 0
}

shopt -s nullglob
manifests=( "$CORPUS_DIR"/must-not-flag/*/manifest.json "$CORPUS_DIR"/must-catch/*/manifest.json )
shopt -u nullglob
[ "${#manifests[@]}" -gt 0 ] || { echo "❌ no fixtures under $CORPUS_DIR" >&2; exit 2; }

echo "Calibrating ${OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER:-OPENCODE-GO-DECISIONS} on ${#manifests[@]} planted findings × 3 variants (as-is, stripped, stripped+rules)…"
# Plain batches, not `wait -n` (Bash 3.2, same reason as the scorer).
jobs_in_batch=0
for variant in as-is stripped stripped+rules; do
  for m in "${manifests[@]}"; do
    calibrate_one "$m" "$variant" &
    jobs_in_batch=$((jobs_in_batch + 1))
    if [ "$jobs_in_batch" -ge "$PARALLEL" ]; then wait; jobs_in_batch=0; fi
  done
done
wait

if command -v python3 >/dev/null 2>&1; then
  python3 "$REPORT" "$OUT/as-is" "PLANTED FINDINGS — as-is (fixture comments kept)" || true
  echo ""
  python3 "$REPORT" "$OUT/stripped" "PLANTED FINDINGS — stripped (comments removed; code only)" || true
  echo ""
  python3 "$REPORT" "$OUT/stripped+rules" "PLANTED FINDINGS — stripped + project rules (code only, standards given)" || true
else
  echo "ℹ️  Records written to $OUT; no python3 to summarise them."
fi
echo ""
echo "Records: $OUT/{as-is,stripped,stripped+rules}/"
exit 0
