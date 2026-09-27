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
#              The LAST decision for a finding wins, deferred included: a later
#              deferred removes an earlier record, and a corrected decision
#              refreshes it. A record already matching the latest decision is
#              not downloaded again; one that cannot be refreshed (artifact
#              expired) is removed rather than kept with the old label.
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
# Since LADR-098 a record also carries the gate's fix_skip prediction (what
# this human decision is measured against) and the full reviewed head plus the
# base branch tip, from which a later re-score resolves the merge base.
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

# decision_blocks — PR body on stdin → one "<run> <n> <label>:<reason>" line
# per decision: tp/fp for harvestable ones, `none` for deferred or unrecognised
# ones. Non-harvestable decisions are kept on purpose, so they still take part
# in last-decision-wins and can supersede an earlier label. The block is an HTML comment, so it is invisible in
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
      else if (d == "skip deferred") print run, n, "none:deferred"
      else print run, n, "none:unrecognised"
    }'
}

# from_pr <number> [body_file] — harvest every labelled run in one PR.
from_pr() {
  local pr="$1" body="${2:-}" pairs runs run labels harvest stale f n l rec rc=0
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
    # review corrects the first — including a correction to `deferred`.
    labels="$(printf '%s\n' "$pairs" | awk -v r="$run" '$1 == r { last[$2] = $3; if (!($2 in seen)) { seen[$2] = 1; order[++k] = $2 } }
      END { for (i = 1; i <= k; i++) printf "%s=%s ", order[i], last[order[i]] }')"
    harvest=""; stale=""
    for f in $labels; do
      n="${f%%=*}"; l="${f#*=}"
      rec="$OUT/pr${pr}-run${run}-f${n}.json"
      case "$l" in
        none:*)
          # The human's latest word is "not a label". An earlier record for
          # this finding is now wrong ground truth, so it goes.
          if [ -f "$rec" ]; then
            rm -f "$rec"
            echo "ℹ️  PR $pr run $run finding $n: latest decision is ${l#none:} — earlier label removed"
          fi
          continue ;;
      esac
      # Harvest when the record is missing OR carries a superseded decision.
      if [ ! -f "$rec" ]; then
        harvest="$harvest $f"
      elif [ "$(jq -r '"\(.label):\(.label_reason // "")"' "$rec" 2>/dev/null)" != "$l" ]; then
        harvest="$harvest $f"; stale="$stale $n"
      fi
    done
    if [ -z "$harvest" ]; then
      echo "ℹ️  PR $pr run $run: already harvested"
      continue
    fi
    # shellcheck disable=SC2086 # labels are whitespace-separated n=label pairs
    if ! bash "${BASH_SOURCE[0]}" --repo "$REPO" --pr "$pr" --out "$OUT" "$run" $harvest; then
      echo "⚠️  PR $pr run $run: not harvested (artifact expired, or the run was not scored) — continuing" >&2
      rc=1
      # A record the human has since corrected must not survive a failed
      # refresh: a missing label costs data, a wrong one poisons the measure.
      # Re-checked per record, because the refresh may have rewritten some.
      for n in $stale; do
        rec="$OUT/pr${pr}-run${run}-f${n}.json"
        l="$(printf '%s\n' $harvest | awk -F= -v n="$n" '$1 == n { print $2 }')"
        if [ -f "$rec" ] && [ "$(jq -r '"\(.label):\(.label_reason // "")"' "$rec" 2>/dev/null)" != "$l" ]; then
          rm -f "$rec"
          echo "⚠️  PR $pr run $run finding $n: superseded label removed — the corrected decision ($l) could not be harvested" >&2
        fi
      done
    fi
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
# The reviewed revision in full (LADR-098), so a record can be re-scored later
# against the exact code the finding was raised on (LADR-096 phase 4).
# metadata.json's base_sha is the base BRANCH TIP at review time
# (pull_request.base.sha), NOT the merge base: it is recorded as `base_tip`,
# and a re-score must resolve the merge base itself (lib/resolve-diff-base.sh)
# — a two-dot range from a tip re-imports the base's newer commits inverted
# (LADR-075).
meta="$(dirname "$merged")/metadata.json"
head_full="$(jq -r '.head_sha // "" | select(test("^[0-9a-f]{40}$"))' "$meta" 2>/dev/null || true)"
base_tip="$(jq -r '.base_sha // "" | select(test("^[0-9a-f]{40}$"))' "$meta" 2>/dev/null || true)"
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
  jq --argjson n "$n" --arg label "$label" --arg reason "$reason" --arg run "$RUN" --arg sha "$sha" --arg pr "${PR:-}" \
     --arg head "$head_full" --arg base_tip "$base_tip" '
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
        source: ({ run: ($run | tonumber), commit: $sha, pr: $pr, number: $n }
                 + (if $head != "" then { head: $head } else {} end)
                 + (if $base_tip != "" then { base_tip: $base_tip } else {} end)),
        provider: $ds.provider, model: $ds.model,
        findings: [ $f | { severity, verified: (.verified == true), confidence, title, why_it_matters,
                           file, line, first_evidence,
                           supported: (.decisions.supported // null),
                           jev_severity: (.decisions.severity.choice // null),
                           jev_confidence: (.decisions.severity.confidence // null),
                           sanctioned: (.decisions.sanctioned // null),
                           previously_skipped: (.decisions.previously_skipped // null),
                           diff_hunk_found: (.decisions.diff_hunk_found // null),
                           code_context: (.decisions.code_context // null),
                           # The gate PREDICTION of this label (LADR-098),
                           # recorded beside the human decision — a score to
                           # measure, never itself a label.
                           fix_skip: (.decisions.fix_skip.choice // null),
                           fix_skip_p: (.decisions.fix_skip.skip_probability // null) } ] }' \
    "$merged" > "$out"
  n_written=$((n_written + 1))
done
echo "✅ $n_written labelled finding(s) from run $RUN (PR ${PR:-?}, $sha) → $OUT"
