# NFR-03: Trigger Coverage

**Status:** Accepted

## Requirement

Every push from the dedicated commit path, and every push that follows a Critical-or-High review,
has a head commit whose full message matches the gate's `/ai-review` matcher. No commit before the
final one carries the trigger. A clean working tree still verifies or amends the head before pushing.

## Verification

Check the pushed range with the same whole-message matcher the gate uses. Exercise four cases:
dirty tree with fixes, clean tree with unpushed commits, clean tree with nothing to push, and a
Medium-only review.

## Acceptance Criteria

- The head always matches the trigger on the dedicated commit path and when the review was Critical
  or High.
- Earlier commits never match.
- Nothing-to-push reports and stops without pushing.

## Applies To

Goal 4; the commit and push path.
