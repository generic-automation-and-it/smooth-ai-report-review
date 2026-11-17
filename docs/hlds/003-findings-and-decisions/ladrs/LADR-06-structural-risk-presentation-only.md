# LADR-06: Structural Risk Is a Presentation-Only Section

**Status:** Accepted

## Context

- The code graph knows the PR's overall risk, change frequency, affected flows, direct versus
  indirect test gaps and removed symbols that are still referenced. Reviewers asked to see it.
- Three parsers read the posted body by section: the Issues Summary until the next `## ` heading,
  the Suggested Fixes until the Recommendation, and the severity lists until the next heading.
- Graph data is inferred and may be stale; it must never count as a finding or move the verdict.
- The posted body has a size ceiling, and truncation already has a ladder.

## Decision

**Render** the graph data as an opt-in `## 🧭 Structural Risk (graph)` section of its own, placed
directly after the Issues Summary section and before the Suggested Fixes and the Recommendation. It
is added to the assembled body after the inputs the action is derived from have been read. It
carries no numbered line, severity marker or `#`+digit token. When the expected headings are missing
(a fail-closed stub, an incremental body without one of them, or malformed orchestrator output), it
is placed after the header and banner region, else at the end; model prose is never rewritten. The
size ladder drops the whole section before any compaction or truncation.

**Rejected:** splicing the data into the Issues Summary as extra bullets or a sub-heading. Every
section-bounded parser would read it as part of the findings document, and a sub-heading placed
before the Recommendation would also leak into the Suggested Fixes that the autonomous fixer reads.

## Consequences

- With the section present or absent, every consumer parser returns identical results.
- Counts, `MACHINE_READABLE_ACTION` and the posted state never depend on graph data.
- A truncated body never carries half a section.
- LADR-05 stays scoped to permalinks and cross-reference repair.

## Related

- Canonical **LADR-050** (amendment) and **LADR-067**, **LADR-068** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
- [HLD-001 Goal 4](../../001-review-gate-pipeline/README.md) — the size ladder that drops it first.
