# NFR-03: Post Determinism

**Status:** Accepted

## Requirement

A run posts one gate-authored review per verified write, anchored to the reviewed SHA rather than
the PR head at post time. An uncertain write verification permits exactly one bounded retry, whose
duplicate is cosmetic and minimized on the next full review. The run artifact identifies the run
that produced the posted review, and stale gate reviews are minimized on full reviews only.

## Verification

Assert the posted review's `commit_id` equals the reviewed SHA in a posting test, and count
gate-authored reviews per run from the PR timeline. Include a case where the PR head advances
between the review and the post, and an uncertain-verification retry case.

**Test mapping:** `test-post-review.sh` and `test-minimize-reviews.sh`.

## Acceptance Criteria

- No review is anchored to a commit other than the one reviewed.
- A verified write produces one gate review; a duplicate from an uncertain retry is cosmetic and
  minimized later.
- Full reviews minimize prior gate reviews; incremental reviews do not.

## Applies To

Goal 4; the posting, minimization and artifact-upload flow.
