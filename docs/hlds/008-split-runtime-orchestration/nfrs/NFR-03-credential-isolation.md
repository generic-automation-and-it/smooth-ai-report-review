# NFR-03: Per-attempt credential isolation

**Status:** Draft

## Requirement

Every model attempt, on either runtime, executes with exactly one provider key in its environment; no
other provider key, GitHub token, or OIDC/cloud credential is present.

## Verification

A component test stubs the runtime executable and dumps the child environment for a single-provider and a
two-provider chain; assertions require the attempt's key and absence of all others.

## Acceptance Criteria

- The attempt's provider key is present.
- No other provider key, GitHub token, or cloud credential is present.
- A chain spanning two providers shows a different single key per attempt.

## Applies To

Goal 6; chunk and orchestration roles; both runtimes.
