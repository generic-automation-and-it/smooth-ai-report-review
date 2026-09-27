#!/bin/bash
# review-findings-to-json.sh — rebuild a scoreable findings document from a
# POSTED gate review body (LADR-097).
#
# Usage: review-findings-to-json.sh <review_md> [artifact_merged_json] [severities]
#   review_md            : the posted review body, or just the Medium/Low
#                          sections ai-analyse's guard extracted
#   artifact_merged_json : OPTIONAL findings.merged.json from the run artifact
#                          of the run that posted <review_md> (LADR-062). Used
#                          only to ENRICH a parsed finding with the fields the
#                          body never renders (quoted evidence, chunks, and —
#                          LADR-098 — the gate's own `decisions`, carried as
#                          `gate_decisions` for lib/recommend-fix-skip.sh to
#                          reuse or not) — never as the finding list itself.
#   severities           : OPTIONAL comma list (critical,high,medium,low);
#                          blank = all four
#
# Prints a document in merge-findings.py's shape (`status: complete`,
# `findings[]` with `#`, severity, title, file, line, …) that
# lib/score-findings-decisions.sh accepts. Always exits 0; a body with no
# parseable numbered finding yields `findings: []`, which the scorer treats as
# "nothing to score".
#
# Why the posted body and not the artifact
# ----------------------------------------
# The two consumers — `/ai-review --usedecisions` (local) and `ai-analyse`
# (CI) — both start from the review a human or the guard actually READ. That
# body is the trust boundary ai-analyse is built around (LADR-042), and the
# artifact expires, may belong to a different run, or may not exist at all
# (structured findings off, artifacts off). So the list and the numbers come
# from the body, and the artifact can only add evidence to a finding it
# provably describes: same number, same file, same title. Anything else is
# ignored, so a mismatched artifact degrades to "no evidence", never to scores
# attached to the wrong finding.
#
# Grammar parsed (lib/render-findings-summary.sh `bullet`, LADR-068):
#   N. <emoji> [VERIFIED|SPECULATIVE] <Severity label>[ (decision …)]: <title> — `file:line`<rest>
#      - <why_it_matters>
# A review whose summary was written by the orchestrator instead (structured
# findings off, or the merge failed) has no such lines, and yields nothing.
set -uo pipefail

review="${1:-}"
artifact="${2:-}"
severities="${3:-}"

if [ -z "$review" ] || [ ! -f "$review" ] || ! command -v jq >/dev/null 2>&1; then
  printf '{"status":"complete","source":"none","findings":[],"residual_risks":[],"testing_gaps":[],"pre_existing_findings":[],"merged_chunks":[]}\n'
  exit 0
fi

art_file="$(mktemp 2>/dev/null || echo "${review}.art.json")"
trap 'rm -f "$art_file"' EXIT
if [ -n "$artifact" ] && [ -s "$artifact" ] && jq -e '.findings | type == "array"' "$artifact" >/dev/null 2>&1; then
  jq -c '.' "$artifact" > "$art_file"
else
  echo 'null' > "$art_file"
fi

jq -R -s --slurpfile art "$art_file" --arg severities "$severities" '
  def clean: gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "");
  def sev_key:
    if . == "Critical" then "critical"
    elif . == "High Priority" then "high"
    elif . == "Medium Priority" then "medium"
    else "low" end;

  (split("\n")) as $all
  # Only the Issues Summary when the input is a whole body: the detailed
  # per-chunk sections carry the chunk reviewers own markdown, which is not
  # numbered by the merge and must never be mistaken for a finding.
  | ([ $all | to_entries[] | select(.value | test("^## 🔍 Issues Summary")) | .key ] | first) as $start
  | (if $start == null then $all
     else $all[($start + 1):]
          | (([ to_entries[] | select(.value | test("^## ")) | .key ] | first) // length) as $end
          | .[0:$end]
     end) as $lines
  | ($severities | split(",") | map(clean | ascii_downcase) | map(select(. != ""))) as $want
  | ($art[0] // null) as $a
  | [ range(0; $lines | length) as $i
      | ($lines[$i]
         | capture("^(?<n>[0-9]+)\\. \\S+ \\[(?<tag>VERIFIED|SPECULATIVE)\\] (?<sev>Critical|High Priority|Medium Priority|Low Priority)(?: \\([^)]*\\))?: (?<title>.*) — `(?<loc>[^`]+)`(?<rest>.*)$")?)
      | . as $m
      # [ … ] | first: a bare capture? yields NOTHING on a miss, and binding
      # nothing with `as` would drop the whole finding, not just its why.
      | ([ $lines[$i + 1] // "" | capture("^   - (?<why>.*)$")? | .why ] | first) as $why
      | ($m.loc | capture("^(?<file>.*):(?<line>[^:]*)$")? // { file: $m.loc, line: "" }) as $loc
      | { "#": ($m.n | tonumber),
          severity: ($m.sev | sev_key),
          title: ($m.title | clean),
          file: $loc.file,
          line: (if ($loc.line | test("^[0-9]+$")) then ($loc.line | tonumber) else $loc.line end),
          verified: ($m.tag == "VERIFIED") }
        + (if $why != null and ($why | clean) != "" then { why_it_matters: ($why | clean) } else {} end) ]
  # A number is an identity: keep the first occurrence only.
  | reduce .[] as $f ([]; if any(.[]; .["#"] == $f["#"]) then . else . + [$f] end)
  | map(select(($want | length) == 0 or (.severity as $s | $want | index($s))))
  | (if $a == null then . else
       map(. as $f
           | ([ $a.findings[]?
                | select(.["#"] == $f["#"] and .file == $f.file and ((.title // "") | clean) == $f.title) ]
              | first) as $src
           | if $src == null then $f
             else $f
                  + ($src | { evidence, first_evidence, chunks, confidence } | with_entries(select(.value != null)))
                  + (if ($f.why_it_matters // "") == "" and ($src.why_it_matters // "") != ""
                     then { why_it_matters: $src.why_it_matters } else {} end)
                  + (if ($src.decisions | type) == "object" then { gate_decisions: $src.decisions } else {} end)
                  + { enriched_from_artifact: true }
             end)
     end) as $findings
  | { status: "complete",
      source: (if $a != null and any($findings[]; .enriched_from_artifact == true)
               then "review_body+artifact" else "review_body" end),
      findings: $findings,
      residual_risks: [], testing_gaps: [], pre_existing_findings: [], merged_chunks: [] }
' "$review" 2>/dev/null || printf '{"status":"complete","source":"none","findings":[],"residual_risks":[],"testing_gaps":[],"pre_existing_findings":[],"merged_chunks":[]}\n'
exit 0
