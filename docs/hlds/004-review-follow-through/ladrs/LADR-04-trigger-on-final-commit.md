# LADR-04: The Review Trigger Rides the Final Commit, Before Trailers

**Status:** Accepted

## Context

- The gate greps the whole commit message for the trigger and only the head commit is checked.
- A multi-chunk commit sequence can leave any one of the commits as the head.
- Amending from the subject alone drops the body and every trailer.
- A re-verification pass needs a stable head after all routing writes are complete.
- The dedicated commit path wants a full review every time; review execution wants one only after
  high-severity work.

## Decision

**Place** the review trigger in the last pushed commit's message, preferably immediately before a
final trailer block so trailers continue to parse. The dedicated commit path always carries it. When
a review contains any Critical or High finding, every execution fix commit carries the trigger and
one additional empty re-verification commit follows the routing edits.

A clean-working-tree run verifies or amends the head before pushing, because the commit is unpushed
and an untriggered head would produce an incremental review instead of a full one. Earlier chunk
commits never carry the trigger.

## Consequences

- The next push always produces the intended full review.
- Trailers remain machine-readable.
- Critical-or-High reviews cost one extra empty commit by design.
- Medium- and Low-only reviews avoid both the extra commit and trigger-bearing fix commits.

## Related

- `git-commit-review-push` contract in [SKILL.md](../../../../.agents/skills/git-commit-review-push/SKILL.md);
  mandatory-commit rule in [root AGENTS.md](../../../../AGENTS.md).
