#!/bin/bash
# harvest-real-findings.sh — turn a gate run's live decision scores into
# human-labelled measurement records (LADR-093 evaluation).
#
# Usage: harvest-real-findings.sh [--repo owner/name] [--pr N] [--out DIR] <run_id> <n>=tp|fp[:reason] ...
#        harvest-real-findings.sh [--repo owner/name] [--out DIR] --from-pr <N>
#        harvest-real-findings.sh [--repo owner/name] [--out DIR] --scan [--limit N]
#   <run_id>   a pipeline-code-review-report run whose uploaded run artifact
#              (LADR-062) carries findings.merged.json with `decisions` — i.e.
#              the decisions flag was on for that run
#   <n>=tp|fp  the human verdict on finding n. (the Issues Summary number):
#              tp = a real problem (accepted/fixed), fp = wrong (skipped as
#              intentional or invalid). Unlabelled findings are not harvested.
#              An optional :reason (fix, intentional, invalid) is recorded as
#              `label_reason`, so rule-based and evidence-based false positives
#              can be measured apart.
#   --from-pr  read the labels `/ai-review execute` wrote into PR N's
#              description — one block per processed review:
#                <!-- ai-review-decisions
#                run: <run_id>
#                1: fix
#                2: skip intentional
#                -->
#              fix → tp; skip intentional / skip invalid → fp; skip deferred
#              (a real issue left for later) and anything unrecognised are NOT
#              harvested — a doubtful skip costs a label, it never becomes one.
#              Idempotent: a run whose records all exist is not downloaded again.
#   --scan     --from-pr for every PR in the repo (newest --limit, default 100)
#              whose description carries such a block. A run whose artifact has
#              expired is reported and skipped; the scan continues.
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
FROM_PR=""
SCAN=false
LIMIT=100

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr)   PR="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    --from-pr) FROM_PR="$2"; shift 2 ;;
    --scan) SCAN=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# decision_blocks — PR body on stdin → one "<run> <n> <label>[:<reason>]" line
# per harvestable decision. The block is an HTML comment, so it is invisible in
# the rendered description and stripped from the gate's prompts by
# lib/extract-review-notes.sh. Lines that do not parse are ignored.
decision_blocks() {
  tr -d '\r' | awk '
    /^<!--[[:space:]]*ai-review-decisions[[:space:]]*$/ { inb = 1; run = ""; next }
    inb && /^[[:space:]]*-->/ { inb = 0; next }
    !inb { next }
    /^[[:space:]]*run:[[:space:]]*[0-9]+[[:space:]]*$/ { gsub(/[^0-9]/, ""); run = $0; next }
    run != "" && /^[[:space:]]*[0-9]+:[[:space:]]*/ {
      n = $0; sub(/:.*/, "", n); gsub(/[[:space:]]/, "", n)
      d = $0; sub(/^[^:]*:[[:space:]]*/, "", d); sub(/[[:space:]]+$/, "", d)
      d = tolower(d)
      if (d == "fix") print run, n, "tp:fix"
      else if (d == "skip intentional") print run, n, "fp:intentional"
      else if (d == "skip invalid") print run, n, "fp:invalid"
    }'
}

# from_pr <number> [body_file] — harvest every labelled run in one PR.
from_pr() {
  local pr="$1" body="${2:-}" pairs runs run labels want f rc=0
  if [ -z "$body" ]; then
    body="$(mktemp)"
    gh pr view "$pr" -R "$REPO" --json body -q .body > "$body" || { rm -f "$body"; echo "⚠️  PR $pr: description unreadable — skipped" >&2; return 1; }
  fi
  pairs="$(decision_blocks < "$body")"
  if [ -z "$pairs" ]; then
    echo "ℹ️  PR $pr: no ai-review-decisions labels"
    return 0
  fi
  runs="$(printf '%s\n' "$pairs" | awk '{print $1}' | awk '!seen[$0]++')"
  for run in $runs; do
    # The last decision for a finding wins: a second execute round on the same
    # review corrects the first.
    labels="$(printf '%s\n' "$pairs" | awk -v r="$run" '$1 == r { last[$2] = $3; if (!($2 in seen)) { seen[$2] = 1; order[++k] = $2 } }
      END { for (i = 1; i <= k; i++) printf "%s=%s ", order[i], last[order[i]] }')"
    want=0
    for f in $labels; do
      [ -f "$OUT/pr${pr}-run${run}-f${f%%=*}.json" ] || want=1
    done
    if [ "$want" -eq 0 ]; then
      echo "ℹ️  PR $pr run $run: already harvested"
      continue
    fi
    # shellcheck disable=SC2086 # labels are whitespace-separated n=label pairs
    bash "${BASH_SOURCE[0]}" --repo "$REPO" --pr "$pr" --out "$OUT" "$run" $labels || {
      echo "⚠️  PR $pr run $run: not harvested (artifact expired, or the run was not scored) — continuing" >&2
      rc=1
    }
  done
  return "$rc"
}

if [ -n "$FROM_PR" ]; then
  [[ "$FROM_PR" =~ ^[0-9]+$ ]] || { echo "❌ --from-pr needs a PR number" >&2; exit 2; }
  from_pr "$FROM_PR"
  exit $?
fi
if [ "$SCAN" = true ]; then
  [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || { echo "❌ --limit needs a positive number" >&2; exit 2; }
  scan_dir="$(mktemp -d)"; trap 'rm -rf "$scan_dir"' EXIT
  gh pr list -R "$REPO" --state all --limit "$LIMIT" --json number,body > "$scan_dir/prs.json"
  n_prs=0
  for pr in $(jq -r '.[] | select(.body // "" | test("<!-- *ai-review-decisions")) | .number' "$scan_dir/prs.json"); do
    jq -r --argjson n "$pr" '.[] | select(.number == $n) | .body' "$scan_dir/prs.json" > "$scan_dir/body.md"
    from_pr "$pr" "$scan_dir/body.md" || true
    n_prs=$((n_prs + 1))
  done
  echo "✅ scanned $REPO: $n_prs labelled PR(s) → $OUT"
  exit 0
fi

RUN="${1:-}"; shift || true
[[ "$RUN" =~ ^[0-9]+$ ]] || { echo "❌ usage: $0 [--repo o/n] [--pr N] [--out DIR] <run_id> <n>=tp|fp[:reason] ... | --from-pr N | --scan" >&2; exit 2; }
[ $# -gt 0 ] || { echo "❌ label at least one finding: <n>=tp|fp" >&2; exit 2; }

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
  n="${spec%%=*}"; label="${spec#*=}"; reason=""
  case "$label" in *:*) reason="${label#*:}"; label="${label%%:*}" ;; esac
  [[ "$n" =~ ^[0-9]+$ ]] && [[ "$label" =~ ^(tp|fp)$ ]] && [[ "$reason" =~ ^(|fix|intentional|invalid)$ ]] \
    || { echo "❌ bad label '$spec' (want <n>=tp|fp[:fix|intentional|invalid])" >&2; exit 2; }
  jq -e --argjson n "$n" '[.findings[] | select(.["#"] == $n)] | length == 1' "$merged" >/dev/null \
    || { echo "❌ run $RUN has no finding $n." >&2; exit 2; }
  out="$OUT/pr${PR:-unknown}-run${RUN}-f${n}.json"
  jq --argjson n "$n" --arg label "$label" --arg reason "$reason" --arg run "$RUN" --arg sha "$sha" --arg pr "${PR:-}" '
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
        label: $label, label_reason: (if $reason == "" then null else $reason end),
        source: { run: ($run | tonumber), commit: $sha, pr: $pr, number: $n },
        provider: $ds.provider, model: $ds.model,
        findings: [ $f | { severity, verified: (.verified == true), confidence, title, why_it_matters,
                           file, line, first_evidence,
                           supported: (.decisions.supported // null),
                           jev_severity: (.decisions.severity.choice // null),
                           jev_confidence: (.decisions.severity.confidence // null),
                           sanctioned: (.decisions.sanctioned // null),
                           previously_skipped: (.decisions.previously_skipped // null),
                           diff_hunk_found: (.decisions.diff_hunk_found // null) } ] }' \
    "$merged" > "$out"
  n_written=$((n_written + 1))
done
echo "✅ $n_written labelled finding(s) from run $RUN (PR ${PR:-?}, $sha) → $OUT"
