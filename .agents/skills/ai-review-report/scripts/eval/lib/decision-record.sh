#!/bin/bash
# decision-record.sh — the ONE writer of a decision-measurement record, shared by
# run-evals.sh (record_decisions) and calibrate-decisions.sh. Sourced.
#
# write_decision_record <merged_json> <manifest> <sample> <variant> <total_chunks> <score_log> <out_json>
#
# The status decides whether decisions-report.py may use the sample, so it must
# say what was actually MEASURED, not merely whether a summary exists:
#   scored            every finding got a usable answer
#   no_findings       nothing to judge — a real outcome (a clean DR fixture, a
#                     missed catch), counted like a scored sample
#   partial           some findings unscored (failed request, malformed answer,
#                     over the cap) — excluded: an unscored finding would look
#                     retained by every policy and make it seem catch-safe
#   unavailable       no finding scored (provider refused, preflight failed…),
#                     even when the PR-level question succeeded
#   partial_coverage  the merge ingested fewer chunks than were reviewed — a
#                     catch in the missing sidecar would read as a miss
#   no_merged         the merge produced no document
# Only scored and no_findings are used; every other sample is excluded and
# named by the report, with this note.
write_decision_record() {
  local merged="$1" manifest="$2" sample="$3" variant="$4" total="$5" score_log="$6" out="$7"
  local status note empty
  empty="$(dirname "$out")/.decision-record-empty.json"
  if [ ! -s "$merged" ] || ! jq -e '.status == "complete"' "$merged" >/dev/null 2>&1; then
    status="no_merged"
    note="the merge produced no document"
    echo '{}' > "$empty"
    merged="$empty"
  else
    status="$(jq -r --arg total "${total:-}" '
      ((.findings // []) | length) as $n
      | ((.decisions_summary.scored // 0)) as $scored
      | ((.merged_chunks // []) | length) as $have
      | if ($total | test("^[0-9]+$")) and $have < ($total | tonumber) then "partial_coverage"
        elif $n == 0 then "no_findings"
        elif (.decisions_summary | type) != "object" then "unavailable"
        elif $scored == 0 then "unavailable"
        elif $scored < $n then "partial"
        else "scored" end' "$merged")"
    case "$status" in
      partial_coverage)
        note="$(jq -r --arg total "$total" '"sidecars from \((.merged_chunks // []) | length) of \($total) chunks"' "$merged")" ;;
      partial)
        note="$(jq -r '"scored \(.decisions_summary.scored) of \((.findings // []) | length) findings"' "$merged")" ;;
      unavailable)
        note="$(grep -m1 '⚠️' "$score_log" 2>/dev/null | cut -c1-240)"
        [ -n "$note" ] || note="no finding was scored" ;;
      *) note="" ;;
    esac
  fi
  jq -n --slurpfile d "$merged" --slurpfile man "$manifest" \
    --arg sample "$sample" --arg variant "$variant" --arg status "$status" --arg note "$note" '
    ($d[0] // {}) as $d | $man[0] as $f
    | { fixture: $f.id, kind: $f.kind, sample: ($sample | tonumber),
        variant: (if $variant == "" then null else $variant end),
        min_severity: ($f.min_severity // "HIGH"), forbidden_claim: ($f.forbidden_claim // ""),
        status: $status, note: $note,
        provider: ($d.decisions_summary.provider // null), model: ($d.decisions_summary.model // null),
        findings: [ ($d.findings // [])[]
                    | { severity, verified: (.verified == true), confidence, title, why_it_matters,
                        supported: (.decisions.supported // null),
                        jev_severity: (.decisions.severity.choice // null),
                        jev_confidence: (.decisions.severity.confidence // null),
                        sanctioned: (.decisions.sanctioned // null),
                        previously_skipped: (.decisions.previously_skipped // null),
                        diff_hunk_found: (.decisions.diff_hunk_found // null),
                        code_context: (.decisions.code_context // null),
                        # Asked (the key exists, null when unusable) vs never
                        # asked (no key): an unanswered question must count
                        # against the measurement, not vanish from it.
                        fix_skip_asked: ((.decisions // {}) | has("fix_skip")),
                        fix_skip: (.decisions.fix_skip.choice // null),
                        fix_skip_p: (.decisions.fix_skip.skip_probability // null),
                        fix_skip_conf: (.decisions.fix_skip.confidence // null) } ] }' > "$out"
  rm -f "$empty"
}
