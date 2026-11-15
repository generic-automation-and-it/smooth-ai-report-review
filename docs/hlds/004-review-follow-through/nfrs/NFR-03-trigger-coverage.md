# NFR-03: Trigger Coverage

**Status:** Accepted

## Requirement

Every push from the dedicated commit path, and every push that follows a Critical-or-High review,
has a head commit whose full message matches the gate's `/ai-review` matcher. Only the final chunk
commit carries the trigger on the dedicated commit-and-push path. During review execution containing
any Critical or High finding (fixed or skipped), every fix commit carries the trigger as its last
body line, followed by a separate empty re-verification commit after result routing. A clean working
tree on the dedicated path still verifies or amends the head before pushing.

## Verification

Check the pushed range with the same whole-message matcher the gate uses. Exercise four cases:
dirty tree with fixes, clean tree with unpushed commits, clean tree with nothing to push, and a
Medium-only review.

## Acceptance Criteria

- The head always matches the trigger on the dedicated commit path and when the review was Critical
  or High.
- Earlier chunk commits omit the trigger only on the dedicated commit-and-push path.
- Every execution fix commit matches when the review contains any Critical or High finding, and a
  separate empty re-verification commit follows result routing.
- Nothing-to-push reports and stops without pushing.

## Applies To

Goal 4; the commit and push path.
