# NFR-02: Push Safety

**Status:** Accepted

## Requirement

No push occurs when a suite passes at the pre-fix head and fails after the edits, or when the test
gate times out. An already-red suite does not block. A blocked run keeps the fixes, sets the push to
skipped with a reason, and publishes the diff.

## Verification

Exercise green-to-red, red-before-and-after, all-green and timeout cases. Assert the push outcome,
the skip reason, and the presence of the published diff.

## Acceptance Criteria

- Green-to-red and timeout cases never push.
- Already-red suites are reported without blocking.
- Every blocked case exposes the fix diff and its reason.

## Applies To

Goal 3; the test-gate and publication path.
