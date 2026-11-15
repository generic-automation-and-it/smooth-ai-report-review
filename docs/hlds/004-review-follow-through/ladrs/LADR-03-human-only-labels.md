# LADR-03: Decision Labels Come Only from Explicit Human Choices

**Status:** Accepted

## Context

- Decision labels feed the corpus that measures the decision model's precision and recall.
- A label written from model advice teaches the judge to agree with a model.
- Not every review carries scored findings, so a label needs the run that scored them.
- Soft-item sequences are not scored and cannot become labels.

## Decision

**Record** an invisible decision block only when the processed review carries a run marker, only for
numbered findings, and only for explicit per-item choices a human supplied in that execution run.

Never write the block from analysis, from an all-item opt-in, or from the autonomous fixer. A
doubtful skip records the deferred class, which the corpus harvester ignores, rather than guessing
between intentional and invalid.

## Consequences

- The measured corpus reflects human judgment, not model self-agreement.
- Model recommendations stay advisory without losing their influence on the analysis table.
- Labels remain absent from reviews that were never scored.
- A doubtful skip costs a label instead of corrupting one.

## Related

- Canonical **LADR-096**, **LADR-097** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  fixed label shape in [ai-review AGENTS.md](../../../../.agents/skills/ai-review/AGENTS.md).
