# LADR-04: Only Green-to-Red Suites Block; Timeouts Always Block

**Status:** Accepted

## Context

- Repositories often carry a suite that is already red for unrelated reasons.
- Absolute pass/fail would let one stale suite disable the autonomous loop permanently.
- A timeout means safety could not be established, which is different from a known failure.
- The gate tests a tree that its own suites may modify.

## Decision

**Gate** on regression only: a suite that passes before the fix and fails after it blocks the push.
A suite that was already red is reported without blocking. A timeout always blocks because the
absence of evidence is not evidence of safety.

The gate keeps all of its own state outside the repository and publishes from a single exit path,
so a suite that cleans its own scratch directories cannot delete the gate's report mid-run.

## Consequences

- One stale suite cannot switch the loop off.
- A real regression always stops publication.
- Blocked fixes are preserved and published rather than discarded.
- The gate cannot report a phantom regression from a suite that never ran.

## Related

- Canonical **LADR-057** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  enforcement notes in [ai-analyse AGENTS.md](../../../../.agents/skills/ai-analyse/AGENTS.md).
