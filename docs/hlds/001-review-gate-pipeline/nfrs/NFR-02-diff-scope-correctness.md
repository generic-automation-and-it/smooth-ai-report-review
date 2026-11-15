# NFR-02: Diff Scope Correctness

**Status:** Accepted

## Requirement

Every full review diffs `merge-base(base, head)..head`. Every incremental review diffs the previous
reviewed commit against the head. No review is posted when the base ancestor cannot be resolved, and
the base tip is never substituted.

## Verification

Run deterministic cases over shallow, grafted, already-fetched and divergent histories, asserting
the resolved range and the failure path. Include a case where the base branch gained commits after
the branch point, and a case where only `--unshallow` or `--deepen` can restore ancestry.

**Test mapping:** `test-diff-base.sh` and `test-run-review.sh`.

## Acceptance Criteria

- Resolved cases review only commits reachable from the reviewed head.
- Post-branch-point base commits never appear in the diff.
- Unresolvable histories exit non-zero and post no review.

## Applies To

Goal 1; the diff-base resolution and diff-collection flow.
