# LADR-04: Lost Coverage Fails Closed; Incremental Reviews Never Approve

**Status:** Accepted

## Context

- A model recommendation is not proof that every chunk was reviewed.
- Coverage gaps and code defects are different classes and must not be counted together.
- A PR can be blocked already; a later push must not silently clear that block.
- The posted body and the posted state must never contradict each other.

## Decision

**Adopt** a mechanical, fail-closed coverage rule. An out-of-band failure flag per chunk — never a
grep of review text — forces request-changes when any chunk remains unresolved; the banner carries
the failed count, and each per-chunk section carries the identity. Coverage gaps are reported as
informational items only and never count toward the verdict.

Incremental reviews never approve, because they cannot prove the absence of blockers in code they
did not re-read. Only a full review may approve or clear a block. When every model is unavailable,
no chunk can be reviewed; the gate posts request-changes and exits green.

## Consequences

- A partial review can never become a green merge signal.
- Reviewers can see exactly which chunks were missed.
- A transient failure costs a request-changes verdict until a later full review.
- Coverage language cannot be used to smuggle a code finding into the verdict.

## Related

- Canonical **LADR-004**, **LADR-031**, **LADR-036** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
