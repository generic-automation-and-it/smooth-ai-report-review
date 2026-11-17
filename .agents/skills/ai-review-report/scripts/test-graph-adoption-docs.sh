#!/usr/bin/env bash
# test-graph-adoption-docs.sh — documentation assertions for the graph-data
# adoption (H11: HLD sync; I7: the optional host-provided graph step in the
# interactive skills). Doc-only checks; no code runs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
H="${ROOT}/docs/hlds"

pass=0
fail=0
has() {  # has <label> <file> <fixed string>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then echo "  ✅ $1"; pass=$((pass + 1)); else echo "  ❌ $1 — '$3' not in ${2#"$ROOT"/}"; fail=$((fail + 1)); fi
}
lacks() {
  if [ -f "$2" ] && ! grep -qF -- "$3" "$2"; then echo "  ✅ $1"; pass=$((pass + 1)); else echo "  ❌ $1 — '$3' unexpectedly in ${2#"$ROOT"/}"; fail=$((fail + 1)); fi
}
ok_if() { if [ "$2" = 1 ]; then echo "  ✅ $1"; pass=$((pass + 1)); else echo "  ❌ $1"; fail=$((fail + 1)); fi; }

echo "H11: HLD-002 Context and Toolchain"
has "Goal 3: new hint class opt-in, flag-off byte-identical" "$H/002-context-and-toolchain/README.md" "A new hint class is opt-in, and with its flag off the chunk prompt is byte-identical."
has "Goal 3: older graph names the unavailable feature once" "$H/002-context-and-toolchain/README.md" "degradation line; it never fabricates the signal."
has "Goal 3: hints state what the graph records" "$H/002-context-and-toolchain/README.md" "never that code will break or that tests do not exist."
has "LADR-03 names the three hint kinds as one bounded class" "$H/002-context-and-toolchain/ladrs/LADR-03-enrichment-is-advisory.md" "Deleted-symbol references (what the graph still records as using a symbol the PR removed),
change-frequency risk, and the direct-versus-indirect test classification belong to the same
bounded-hint class."
has "NFR-02 adds degradation visibility" "$H/002-context-and-toolchain/nfrs/NFR-02-enrichment-non-blocking.md" "Degradation is visible"
has "NFR-02 maps test-graph-signals-artifact.sh" "$H/002-context-and-toolchain/nfrs/NFR-02-enrichment-non-blocking.md" "\`test-graph-signals-artifact.sh\`"
has "NFR-02 maps test-code-graph.sh" "$H/002-context-and-toolchain/nfrs/NFR-02-enrichment-non-blocking.md" "\`test-code-graph.sh\`"
has "C1 graph node" "$H/002-context-and-toolchain/diagrams/c4-context.md" "Structural risk (including change-frequency), inferred coverage and deleted-symbol data"

echo "H11: HLD-003 Findings and Decisions"
has "Goal 4: parser invariance with the block" "$H/003-findings-and-decisions/README.md" "With the structural block present or absent, every consumer parser returns identical results"
has "LADR-06 row in the README table" "$H/003-findings-and-decisions/README.md" "[LADR-06](./ladrs/LADR-06-structural-risk-presentation-only.md) | Structural risk is a presentation-only section | Accepted |"
has "LADR-06 records the rejected alternative" "$H/003-findings-and-decisions/ladrs/LADR-06-structural-risk-presentation-only.md" "**Rejected:** splicing the data into the Issues Summary"
lacks "LADR-05 stays scoped to permalinks" "$H/003-findings-and-decisions/ladrs/LADR-05-presentation-only-links.md" "Structural"

echo "H11: HLD-001 Gate Pipeline"
has "Goal 4: degradation named once, never a defect" "$H/001-review-gate-pipeline/README.md" "Enrichment degradation is named once in Coverage and is never counted as a coverage gap or a
  code defect."
has "Goal 4: block after Issues Summary, dropped before truncation" "$H/001-review-gate-pipeline/README.md" "dropped whole before
  body truncation, and never changes counts, the action or the posted state."
has "gate-flow node" "$H/001-review-gate-pipeline/diagrams/c4-context.md" "Aggregate summary (assemble structural hints when enabled) and derive action"

echo "H11: HLD-004 Follow-Through"
has "Goal 1: host-provided queries read-only and optional" "$H/004-review-follow-through/README.md" "Host-provided structural queries are read-only and optional"
has "LADR-01: never builds a graph implicitly" "$H/004-review-follow-through/ladrs/LADR-01-analysis-read-only.md" "It never builds or updates a graph implicitly"
has "NFR-01 scoped to human execute; autonomous skips out of scope" "$H/004-review-follow-through/nfrs/NFR-01-skip-propagation.md" "Autonomous
\`ai-analyse\` skips are out of scope here"

echo "H11: HLD-005 Autonomous Fixer"
has "Goal 1: structural context never widens severity scope" "$H/005-autonomous-fixer/README.md" "never widens the severity
  scope."
has "Key Goal 5 joinable skips" "$H/005-autonomous-fixer/README.md" "### 5. Make every autonomous skip joinable"
has "Key Goal 5 defers the fields to HLD-006 NFR-04" "$H/005-autonomous-fixer/README.md" "are owned by HLD-006 NFR-04"

echo "H11: HLD-006 Distribution and Evaluation"
has "Goal 3: deletion fixture and report-only series" "$H/006-distribution-and-evals/README.md" "The corpus includes a deletion-regression recall fixture"
has "NFR-04 row in the README table" "$H/006-distribution-and-evals/README.md" "[NFR-04](./nfrs/NFR-04-measurement-visibility.md) | Measurement visibility |"
has "NFR-04 never zero" "$H/006-distribution-and-evals/nfrs/NFR-04-measurement-visibility.md" "No measurement reports zero when its input was missing."
has "LADR-03: new series report-only" "$H/006-distribution-and-evals/ladrs/LADR-03-offline-blocking-evals.md" "are report-only. They are printed after the verdict and never
gate a run or a release."
lacks "NFR-02 stays independence-only" "$H/006-distribution-and-evals/nfrs/NFR-02-offline-regression-independence.md" "skip"
has "corpus-ownership note" "$H/006-distribution-and-evals/README.md" "Eval corpus and harness assets are owned by the \`ai-review-report\` skill; this HLD governs their
gating and release role."

echo "H11: index, Evidence and Last updated"
has "index 002 names the deleted-symbol hint" "$H/README.md" "graph hints (risk, coverage, opt-in deleted-symbol)"
has "index 003 names the Structural Risk section" "$H/README.md" "presentation (including the opt-in Structural Risk section)"
has "index 005 names joinable skips" "$H/README.md" "bounded push loop, joinable skips"
has "index 006 names report-only measurement" "$H/README.md" "layered evals and report-only measurement"
ok_if "no HLD folder added (six)" "$([ "$(find "$H" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9]-*' | wc -l | tr -d ' ')" = 6 ] && echo 1 || echo 0)"
for d in 001-review-gate-pipeline 002-context-and-toolchain 003-findings-and-decisions 004-review-follow-through 005-autonomous-fixer 006-distribution-and-evals; do
  readme="$H/$d/README.md"
  ok_if "$d Evidence names a 7-hex commit" "$(grep -E '^\| \*\*Evidence\*\* \|.*`[0-9a-f]{7}`' "$readme" >/dev/null && echo 1 || echo 0)"
  updated="$(sed -n 's/^| \*\*Last updated\*\* | \([0-9-]*\) |$/\1/p' "$readme")"
  ok_if "$d Last updated is on or after the implementation date" "$([[ "$updated" > "2026-11-16" ]] && echo 1 || echo 0)"
done

echo "H11: root AGENTS.md"
has "names the opt-in deleted-symbol class" "$ROOT/AGENTS.md" "is a third, **opt-in** hint class in its own TSV"
has "states the block is presentation-only" "$ROOT/AGENTS.md" "is **presentation-only**: its own \`##\` section after the Issues Summary"

echo "I7: optional host-provided graph step"
for skill in ai-review ai-analyse; do
  f="$ROOT/.agents/skills/$skill/SKILL.md"
  has "$skill: the step is host-provided only" "$f" "already exposes the \`code-review-graph\` CLI or its MCP tools"
  has "$skill: never builds a graph" "$f" "never build or update a graph"
  has "$skill: no allowed-tools change" "$f" "never add a tool to \`allowed-tools\`"
  has "$skill: the source wins" "$f" "source wins over the graph"
  frontmatter="$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$f")"
  ok_if "$skill: allowed-tools carries no graph entry" "$(printf '%s\n' "$frontmatter" | grep -qiE 'code-review-graph|mcp__' && echo 0 || echo 1)"
done
has "ai-analyse: headless CI out of scope" "$ROOT/.agents/skills/ai-analyse/SKILL.md" "Headless CI is out of scope"
has "ai-review: opt-in and read-only, fail-open" "$ROOT/.agents/skills/ai-review/SKILL.md" "skip the step silently when the tool is absent, errors or times out"

echo ""
echo "=========================================="
echo "Results: ${pass} passed, ${fail} failed"
echo "=========================================="
[ "$fail" -eq 0 ]
