# LADR-04: Regression-Relative Suites, Absolute Explicit Commands

**Status:** Accepted

## Context

- Repositories often carry a suite that is already red for unrelated reasons.
- Absolute pass/fail would let one stale suite disable the autonomous loop permanently.
- A timeout means safety could not be established, which is different from a known failure.
- The gate tests a tree that its own suites may modify.

## Decision

**Gate auto-detected suites** on regression: a suite that passes at HEAD and fails after the fix
blocks the push. Failures confirmed at HEAD are reported without blocking. Timeouts, exhausted
budgets and unavailable baselines fail closed because the absence of evidence is not evidence of
safety. An explicit test command uses absolute gating: any nonzero exit blocks publication.

The gate keeps all of its own state outside the repository and publishes from a single exit path,
so a suite that cleans its own scratch directories cannot delete the gate's report mid-run.

## Consequences

- One confirmed stale auto-detected suite cannot switch the loop off.
- A failed explicit command blocks without a HEAD-baseline comparison.
- A real regression always stops publication.
- Test-gate-blocked summaries publish up to 30,000 bytes of tracked-file diff and list new-file names;
  new file contents and a complete recovery patch are not preserved in the run artifact.
- The gate cannot report a phantom regression from a suite that never ran.

## Related

- Canonical **LADR-057** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  enforcement notes in [ai-analyse AGENTS.md](../../../../.agents/skills/ai-analyse/AGENTS.md).
