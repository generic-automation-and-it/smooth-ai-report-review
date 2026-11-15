# LADR-06: Deterministic No-Review Gates Fail Open

**Status:** Accepted

## Context

- A lockfile-only PR has little for a reviewer to assess, so a full model review costs time for no value.
- The documentation-context validation gate is optional and default-off, so it must not silently block.
- Any doubt about the change set should run the review rather than skip it.

## Decision

**Adopt** deterministic pre-review gates that may post guidance and end the run without a model call.
Trivial-PR skip requires every changed file to stay inside the lockfile and manifest allowlist; one
file outside it runs the full review. The documentation gate blocks only when explicitly enforced.
Trusted `/ai-review` comments and manual dispatch always run the full review.

## Consequences

- Lockfile-only PRs avoid model cost without hiding a reviewable change.
- A gate miss fails open to the full review.
- Operators can disable the documentation check without changing review coverage.
- A skip still posts a comment, so the PR state stays visible.

## Related

- Canonical **LADR-059** (trivial skip), **LADR-105** (context defaults), and [root AGENTS.md](../../../../AGENTS.md).
