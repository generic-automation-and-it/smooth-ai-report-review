# LADR-01: Selection Stays Severity-Based; Merged JSON Is Not Consumed Yet

**Status:** Accepted

## Context

- The current selection predicate is "the finding is Medium or Low".
- Severity alone is a poor autonomy signal: a Medium may need product judgment.
- A richer merged document already carries routing and suggested-fix fields.
- The comment-scraping path is what the workflow's trust boundary is built around.

## Decision

**Keep** severity as the selection predicate for now. Read the Medium and Low sections of the
trusted gate-authored review body and treat every identifier in scope as requiring exactly one row.

Do not start reading the structured merged document opportunistically. Switching selection from
severity to routing is a deliberate change with its own trust-boundary work, not an incremental
convenience.

## Consequences

- The fixer's scope remains easy to explain and audit.
- Some mechanically fixable high-severity findings stay human-owned, and some Medium findings still
  require judgment and end in skip.
- The richer document remains available for a future, deliberate migration.
- The workflow's filters and tests continue to target one input shape.

## Related

- Canonical **LADR-042** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  runtime contract in [ai-analyse SKILL.md](../../../../.agents/skills/ai-analyse/SKILL.md).
