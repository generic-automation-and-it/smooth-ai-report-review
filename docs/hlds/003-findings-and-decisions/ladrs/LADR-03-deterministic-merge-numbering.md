# LADR-03: Merge and Numbering Are Deterministic; Coverage Is Loud

**Status:** Accepted

## Context

- The same defect can surface in several chunks with different wording.
- Consumers and the next review round need stable identifiers across a posted body.
- GitHub autolinks any `#` followed by digits, corrupting identifiers in posted text.
- Partial coverage must not look like a complete review.

## Decision

**Merge** by normalized file, line and title. Take the most severe severity, the more conservative
routing value, OR verification flags, and keep pre-existing status only on unanimity. Sort
deterministically and number findings in severity order.

Each item class keeps an independent sequence: findings, residual risks, testing gaps and
pre-existing items. Posted identifiers never use `#` plus digits. Coverage counts merged chunks,
and every missing chunk is named at the top of the coverage block.

## Consequences

- Every consumer can quote an identifier and mean the same item.
- A duplicate cannot be reported twice with different severity.
- Partial reviews remain honest and visibly incomplete.
- Independent sequences mean R/T/P numbers may change between rounds; matching uses their text.

## Related

- Canonical **LADR-055**, **LADR-063**, **LADR-064**, **LADR-067**, **LADR-068** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
