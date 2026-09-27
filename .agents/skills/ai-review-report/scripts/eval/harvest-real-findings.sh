#!/bin/bash
# harvest-real-findings.sh — turn a gate run's live decision scores into
# human-labelled measurement records (LADR-093 evaluation).
#
# Usage: harvest-real-findings.sh [--repo owner/name] [--pr N] [--out DIR] <run_id> <n>=tp|fp ...
#   <run_id>   a pipeline-code-review-report run whose uploaded run artifact
#              (LADR-062) carries findings.merged.json with `decisions` — i.e.
#              the decisions flag was on for that run
#   <n>=tp|fp  the human verdict on finding n. (the Issues Summary number):
#              tp = a real problem (accepted/fixed), fp = wrong (skipped as
#              intentional or invalid). Unlabelled findings are not harvested.
#
# Why this exists: planted findings are textbook defects whose quoted line
# proves them, and the decision model scored every planted true catch >= 0.58.
# The first 12 REAL accepted findings (PR 169) scored mean 0.43, 9 of them
# below 0.5 — they describe behaviour across code, which one diff hunk cannot
# show. Real, labelled findings are the only evidence that transfers to live
# reviews, so they are kept as data: run artifacts expire, these records do
# not. The scores are the ones the gate computed live; nothing is re-scored.
#
# Writes one record per labelled finding to --out (default: the committed
# corpus/real-findings/), in the shape lib/decisions-report.py reads:
#   tp → kind must-catch,    min_severity = the finding's own severity
#   fp → kind must-not-flag, no forbidden_claim (every [VERIFIED] C/H/M counts)
# Needs gh (authenticated) and jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-}"
PR=""
OUT="$SCRIPT_DIR/corpus/real-findings"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr)   PR="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
RUN="${1:-}"; shift || true
[[ "$RUN" =~ ^[0-9]+$ ]] || { echo "❌ usage: $0 [--repo o/n] [--pr N] [--out DIR] <run_id> <n>=tp|fp ..." >&2; exit 2; }
[ $# -gt 0 ] || { echo "❌ label at least one finding: <n>=tp|fp" >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gh run download "$RUN" -R "$REPO" -D "$tmp" >/dev/null
merged="$(find "$tmp" -name findings.merged.json | head -n1)"
[ -n "$merged" ] || { echo "❌ run $RUN has no findings.merged.json in its artifacts (expired, or structured findings were off)" >&2; exit 1; }
jq -e '.decisions_summary | type == "object"' "$merged" >/dev/null \
  || { echo "❌ run $RUN was not scored by the decision model (flag off, or the provider failed)" >&2; exit 1; }
sha="$(gh run view "$RUN" -R "$REPO" --json headSha -q '.headSha[0:7]')"
if [ -z "$PR" ]; then
  branch="$(gh run view "$RUN" -R "$REPO" --json headBranch -q .headBranch)"
  PR="$(gh pr list -R "$REPO" --state all --head "$branch" --json number -q '.[0].number // empty')"
fi
mkdir -p "$OUT"

n_written=0
for spec in "$@"; do
  n="${spec%%=*}"; label="${spec#*=}"
  [[ "$n" =~ ^[0-9]+$ ]] && [[ "$label" =~ ^(tp|fp)$ ]] || { echo "❌ bad label '$spec' (want <n>=tp|fp)" >&2; exit 2; }
  jq -e --argjson n "$n" '[.findings[] | select(.["#"] == $n)] | length == 1' "$merged" >/dev/null \
    || { echo "❌ run $RUN has no finding $n." >&2; exit 2; }
  out="$OUT/pr${PR:-unknown}-run${RUN}-f${n}.json"
  jq --argjson n "$n" --arg label "$label" --arg run "$RUN" --arg sha "$sha" --arg pr "${PR:-}" '
    .decisions_summary as $ds
    | (.findings[] | select(.["#"] == $n)) as $f
    | { fixture: "PR\($pr)-\($sha)-F\($n)",
        kind: (if $label == "tp" then "must-catch" else "must-not-flag" end),
        sample: 1, variant: "real",
        min_severity: (if $label == "tp" then ($f.severity | ascii_upcase) else "HIGH" end),
        forbidden_claim: "",
        # Status from the answer to THIS finding, like lib/decision-record.sh does
        # for a whole sample: a finding the scorer skipped (failed request,
        # malformed answer, over the cap) has no `supported`, and recording it
        # as scored would make every policy look like it kept a real catch.
        status: (if ($f.decisions.supported // null) == null then "unavailable" else "scored" end),
        note: (if ($f.decisions.supported // null) == null
               then "finding \($n). was not scored by the decision model in run \($run)" else "" end),
        label: $label, source: { run: ($run | tonumber), commit: $sha, pr: $pr, number: $n },
        provider: $ds.provider, model: $ds.model,
        findings: [ $f | { severity, verified: (.verified == true), confidence, title, why_it_matters,
                           file, line, first_evidence,
                           supported: (.decisions.supported // null),
                           jev_severity: (.decisions.severity.choice // null),
                           jev_confidence: (.decisions.severity.confidence // null),
                           sanctioned: (.decisions.sanctioned // null),
                           diff_hunk_found: (.decisions.diff_hunk_found // null) } ] }' \
    "$merged" > "$out"
  n_written=$((n_written + 1))
done
echo "✅ $n_written labelled finding(s) from run $RUN (PR ${PR:-?}, $sha) → $OUT"
