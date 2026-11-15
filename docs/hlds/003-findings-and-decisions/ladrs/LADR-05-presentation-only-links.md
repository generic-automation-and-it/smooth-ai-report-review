# LADR-05: Permalinks and Cross-Reference Repair Are Presentation-Only

**Status:** Accepted

## Context

- A reviewer benefits from a link pinned to the reviewed revision.
- Every parser downstream must keep working unchanged.
- The reviewed SHA changes on every push, so a copied link breaks cross-round matching.
- Suggested-fix prose numbers against the orchestrator's summary, which the merge may replace.

## Decision

**Append** a permalink as the last segment of a numbered finding line and make every parser ignore
it. Any skill that copies a finding strips the link first. The body-size ladder strips links before
truncation can cut the summary.

Suggested-fix references are repointed from each block's file-and-line anchor, not from prose. A
reference whose anchor did not survive is reworded without a number and explained.

## Consequences

- Findings are navigable in the posted review without coupling any consumer to the URL.
- Cross-round skip matching survives pushes.
- A fix can no longer point at a finding the merge removed.
- The renderer, not the parser, owns presentation changes.

## Related

- Canonical **LADR-088**, **LADR-122** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
