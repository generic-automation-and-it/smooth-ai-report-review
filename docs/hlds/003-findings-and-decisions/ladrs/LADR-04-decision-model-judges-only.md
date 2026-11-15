# LADR-04: The Decision Model Judges, Never Authors, and Softens Only Inside a Fence

**Status:** Accepted

## Context

- A second opinion can catch weakly evidenced findings the chunk reviewer trusted.
- A model that can rewrite findings becomes a second, unreviewed author.
- Filtering findings can soften a verdict, which is the dangerous direction.
- The judge needs the same context a human would check, or it scores on prose alone.

## Decision

**Keep** the decision model as a judge over the merged document. It scores support, severity,
pre-existing status, actionability and fix-or-skip, but never rewrites severity, confidence or
verification. Its PR-level answers are facts for the orchestrator, not verdict inputs.

Annotation is the default. Suppression is a separate mode, fenced by full coverage and no unresolved
chunk failure, and degrades to annotation otherwise. Escalation from merged findings is
one-directional; the only softening path is the recommendation sync inside the same fence. An
unusable answer leaves the finding unscored rather than discarding it.

## Consequences

- A weak finding can be demoted visibly without becoming invisible.
- Filtering cannot turn a partial review into a greener one.
- A disabled or preflight-failed judge leaves the document byte-identical; a single failed answer
  leaves only that finding unscored.
- Consumers may reuse a gate answer while the skip areas, provider and model still match.

## Related

- Canonical **LADR-093**, **LADR-096**, **LADR-097**, **LADR-098** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
