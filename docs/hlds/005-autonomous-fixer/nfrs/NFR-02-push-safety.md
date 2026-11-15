# NFR-02: Push Safety

**Status:** Accepted

## Requirement

No push occurs when an auto-detected suite passes at HEAD and fails after the edits. Auto-detected
failures confirmed at HEAD do not block. Timeouts, exhausted budgets and unavailable baselines
fail closed. An explicit test command uses absolute gating: any nonzero exit blocks publication.
A blocked run keeps the fixes, sets the push to skipped with a reason, and publishes the diff.

## Verification

Exercise auto-detected green-to-red, red-before-and-after and all-green cases, plus timeouts,
exhausted budgets, unavailable baselines and failed explicit commands. Assert the push outcome,
the skip reason, and the presence of the published diff.

## Acceptance Criteria

- Green-to-red and timeout cases never push.
- Auto-detected suites confirmed already red at HEAD are reported without blocking.
- Failed explicit commands, exhausted budgets and unavailable baselines never push.
- Every blocked case exposes the fix diff and its reason.

## Applies To

Goal 3; the test-gate and publication path.
