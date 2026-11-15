# NFR-03: Trigger Coverage

**Status:** Accepted

## Requirement

Every push from the dedicated commit path, and every push that follows a Critical-or-High review,
has a head commit whose full message matches the gate's `/ai-review` matcher. Only the final chunk
commit carries the trigger on the dedicated path. Execution-side trigger and empty re-verification
rules are owned by [root AGENTS.md](../../../../AGENTS.md). A clean working tree still verifies or
amends the head before pushing.

## Verification

Check the pushed range with the same whole-message matcher the gate uses. Exercise four cases:
dirty tree with fixes, clean tree with unpushed commits, clean tree with nothing to push, and a
Medium-only review. Test mapping: `test-run-review.sh` covers event-payload and comment-trigger
handling, not commit-message coverage. Verify the four commit-path cases manually using the matcher
and pre-push checks in [git-commit-review-push SKILL.md](../../../../.agents/skills/git-commit-review-push/SKILL.md).

## Acceptance Criteria

- The head always matches the trigger on the dedicated path and when the review was Critical or High.
- Earlier chunk commits omit the trigger only on the dedicated path.
- Execution fix commits and the separate empty re-verification commit follow root AGENTS.md.
- Nothing-to-push reports and stops without pushing.

## Applies To

Goal 4; the commit and push path.
