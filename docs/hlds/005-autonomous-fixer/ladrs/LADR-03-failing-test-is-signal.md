# LADR-03: Failing-Test Findings Are Withheld Before the Model Sees Them

**Status:** Accepted

## Context

- A failing test may mean the code is wrong or the test is stale.
- Automatically making the test pass destroys the only evidence that a disagreement existed.
- A prompt rule is not enough for an unattended loop.
- The fixer cannot know which side a human would choose.

## Decision

**Withhold** any finding whose basis is a failing test before the model is invoked, regardless of
the self-fix flag. Report the withheld findings in the summary so the filtering is auditable.

Never change production code to satisfy a failing test. The prompt rule is reinforced
unconditionally as a second layer, not as the primary enforcement.

## Consequences

- The decision between code and test remains human-owned.
- Some real defects wait for a human instead of being auto-fixed.
- The summary explains why a finding received no autonomous action.
- Filtering is testable independently of model behavior.

## Related

- Canonical **LADR-056** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  enforcement notes in [ai-analyse AGENTS.md](../../../../.agents/skills/ai-analyse/AGENTS.md).
