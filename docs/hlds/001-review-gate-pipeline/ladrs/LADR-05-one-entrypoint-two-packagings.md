# LADR-05: One Entrypoint Serves Both Packagings

**Status:** Accepted

## Context

- Some organizations cannot allow a cross-org reusable-workflow call.
- Two copies of the review logic would drift, and the drift would be invisible.
- The entrypoint needs the runtime it is given, not the workflow's expression context.
- A caller can run the entrypoint from a different checkout shape.

## Decision

**Keep** one entrypoint as the single source of truth and let the packaging supply only environment
variables and event state. New review behaviour goes into the entrypoint; the workflow and the
local-job caller change only for the environment contract, error plumbing or the lookup of the
skill folder.

The entrypoint resolves its own skill directory for callers outside the standard checkout shape.
Any variable the entrypoint reads is declared in both packagings in the same change.

## Consequences

- Both channels run identical review logic.
- A packaging change cannot silently alter review behaviour.
- Every new knob costs a declaration in two places, enforced by review.
- The local-job packaging still requires the same third-party code to run, which needs explicit
  security sign-off.

## Related

- Canonical **LADR-037**, **LADR-108** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  packaging contract in [root AGENTS.md](../../../../AGENTS.md).
