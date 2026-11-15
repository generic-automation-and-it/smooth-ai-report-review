# LADR-06: No-Review Gates Fail Open

**Status:** Accepted

## Context

- A lockfile-only PR has little for a reviewer to assess, so a full model review costs time for no value.
- The documentation-context validation gate is optional and default-off, so it must not silently block.
- Any doubt about the change set should run the review rather than skip it.

## Decision

**Adopt** a two-stage trivial-PR skip: every changed file must first stay inside the lockfile and
manifest allowlist, then a model must return an exact case-insensitive `yes`. One file outside the
allowlist, any other answer, or a model failure runs the full review.
The optional documentation validation gate is deterministic and blocks only when explicitly enforced.
Trusted `/ai-review` comments and manual dispatch always run the full review.

## Consequences

- Confirmed trivial PRs avoid the full review's model cost, but still require a classification call.
- A gate miss fails open to the full review.
- Operators can disable the documentation check without changing review coverage.
- A skip still posts a comment, so the PR state stays visible.

## Related

- Canonical **LADR-059** (trivial skip), **LADR-105** (context defaults), and [root AGENTS.md](../../../../AGENTS.md).
